package com.azmi010.mi_virtual_background_kit.spike

import android.graphics.Matrix
import android.opengl.GLES11Ext
import android.opengl.GLES20
import org.webrtc.GlUtil
import org.webrtc.TextureBufferImpl
import org.webrtc.VideoFrame
import org.webrtc.YuvConverter
import java.nio.FloatBuffer

/**
 * Spike T0.7: GPU compositor.
 *
 * Takes the camera frame (a GPU texture) and draws it into a second texture
 * with a solid colour mixed in, then returns the new frame so libwebrtc
 * encodes the composited image.
 *
 * Runs on the caller's thread. libwebrtc delivers camera frames on the capture
 * thread, which already has the shared EGL context current, so no additional
 * EGL setup is needed here.
 */
class SpikeGpuCompositor {
    private var program = 0
    private var fbo = 0
    private var outTexture = 0
    private var outWidth = 0
    private var outHeight = 0
    private var vertexBuffer: FloatBuffer? = null
    private var texMatrixBuffer: FloatBuffer? = null
    private val yuvConverter = YuvConverter()

    private var aPosLoc = 0
    private var aTexLoc = 0
    private var uMvpLoc = 0
    private var uTexLoc = 0

    /** Microseconds spent in the last compose call. */
    @Volatile
    var compositeMicros: Long = 0
        private set

    @Volatile
    var compositeCount: Long = 0
        private set

    /**
     * Reads the camera texture back into a CPU RGBA buffer.
     *
     * Segmentation engines need CPU pixels, so this is the unavoidable cost of
     * running person segmentation in a GPU pipeline.
     */
    fun readBackRgba(buffer: VideoFrame.TextureBuffer): ByteArray? {
        val width = buffer.unscaledWidth
        val height = buffer.unscaledHeight
        val isOes = buffer.type == VideoFrame.TextureBuffer.Type.OES
        val target = if (isOes) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D

        val out = ByteArray(width * height * 4)
        val outBuffer = java.nio.ByteBuffer.allocateDirect(out.size).put(out)
        outBuffer.position(0)
        val start = System.nanoTime()
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, buffer.textureId)
        // An external OES texture cannot be sampled with glReadPixels directly,
        // so it is first drawn into a regular texture.
        if (isOes) {
            if (outWidth != width || outHeight != height) {
                createOutput(width, height)
            }
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            GLES20.glViewport(0, 0, outWidth, outHeight)
            drawCamera(buffer, target)
            GLES20.glReadPixels(
                0, 0, outWidth, outHeight, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, outBuffer,
            )
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        } else {
            GLES20.glReadPixels(
                0, 0, width, height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, outBuffer,
            )
        }
        readbackMicros = (System.nanoTime() - start) / 1000
        readbackWidth = width
        readbackHeight = height
        return out
    }

    private fun drawCamera(buffer: VideoFrame.TextureBuffer, target: Int) {
        if (program == 0) buildProgram()
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, buffer.textureId)
        GLES20.glUniform1i(uTexLoc, 0)
        val matrix = FloatArray(9)
        buffer.transformMatrix?.getValues(matrix)
        val m4 = floatArrayOf(
            matrix[0], matrix[1], matrix[2], 0f,
            matrix[3], matrix[4], matrix[5], 0f,
            matrix[6], matrix[7], matrix[8], 0f,
            0f, 0f, 0f, 1f,
        )
        texMatrixBuffer?.position(0)
        texMatrixBuffer?.put(m4)
        texMatrixBuffer?.position(0)
        GLES20.glUniformMatrix4fv(uMvpLoc, 1, false, m4, 0)
        vertexBuffer?.position(0)
        GLES20.glEnableVertexAttribArray(aPosLoc)
        GLES20.glVertexAttribPointer(aPosLoc, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer)
        texMatrixBuffer?.position(0)
        GLES20.glEnableVertexAttribArray(aTexLoc)
        GLES20.glVertexAttribPointer(aTexLoc, 2, GLES20.GL_FLOAT, false, 0, texMatrixBuffer)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPosLoc)
        GLES20.glDisableVertexAttribArray(aTexLoc)
    }

    @Volatile
    var lastInputType: String = ""
        private set

    /** Microseconds for a raw glReadPixels of the camera texture into RGBA. */
    @Volatile
    var readbackMicros: Long = 0
        private set

    @Volatile
    var readbackWidth: Int = 0
        private set

    @Volatile
    var readbackHeight: Int = 0
        private set

    private val identity = floatArrayOf(
        1f, 0f, 0f, 0f,
        0f, 1f, 0f, 0f,
        0f, 0f, 1f, 0f,
        0f, 0f, 0f, 1f,
    )

    private val vertices = floatArrayOf(
        -1f, -1f,
        1f, -1f,
        -1f, 1f,
        1f, 1f,
    )

    fun compose(frame: VideoFrame, color: FloatArray): VideoFrame? {
        val buffer = frame.buffer as? VideoFrame.TextureBuffer ?: return null
        if (program == 0) buildProgram()
        val width = buffer.unscaledWidth
        val height = buffer.unscaledHeight
        val start = System.nanoTime()

        if (outWidth != width || outHeight != height) {
            createOutput(width, height)
        }

        val textureId = buffer.textureId
        val isOes = buffer.type == VideoFrame.TextureBuffer.Type.OES
        lastInputType = buffer.type.toString()
        val target = if (isOes) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, textureId)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glViewport(0, 0, outWidth, outHeight)
        GLES20.glClearColor(color[0], color[1], color[2], 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        GLES20.glUseProgram(program)
        GLES20.glUniform1i(uTexLoc, 0)

        val matrix = FloatArray(9)
        buffer.transformMatrix?.getValues(matrix)
        // The texture transform is a 3x3 affine matrix; GL wants 4x4.
        val m4 = floatArrayOf(
            matrix[0], matrix[1], matrix[2], 0f,
            matrix[3], matrix[4], matrix[5], 0f,
            matrix[6], matrix[7], matrix[8], 0f,
            0f, 0f, 0f, 1f,
        )
        texMatrixBuffer?.position(0)
        texMatrixBuffer?.put(m4)
        texMatrixBuffer?.position(0)
        GLES20.glUniformMatrix4fv(uMvpLoc, 1, false, m4, 0)

        vertexBuffer?.position(0)
        GLES20.glEnableVertexAttribArray(aPosLoc)
        GLES20.glVertexAttribPointer(aPosLoc, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer)
        texMatrixBuffer?.position(0)
        GLES20.glEnableVertexAttribArray(aTexLoc)
        GLES20.glVertexAttribPointer(aTexLoc, 2, GLES20.GL_FLOAT, false, 0, texMatrixBuffer)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPosLoc)
        GLES20.glDisableVertexAttribArray(aTexLoc)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

        val out = TextureBufferImpl(
            width,
            height,
            VideoFrame.TextureBuffer.Type.RGB,
            outTexture,
            Matrix(),
            null,
            yuvConverter,
            Runnable { },
        )

        compositeMicros = (System.nanoTime() - start) / 1000
        compositeCount++
        return VideoFrame(out, frame.rotation, frame.timestampNs)
    }

    private fun createOutput(width: Int, height: Int) {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        outTexture = textures[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, outTexture)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
        )
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val buffers = IntArray(1)
        GLES20.glGenFramebuffers(1, buffers, 0)
        fbo = buffers[0]
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, outTexture, 0,
        )
        val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
        android.util.Log.i(
            "MiVBGSpike",
            "fbo status=$status complete=${GLES20.GL_FRAMEBUFFER_COMPLETE} size=${width}x$height",
        )
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        outWidth = width
        outHeight = height
    }

    private fun buildProgram() {
        val vertexShader = """
            attribute vec4 aPos;
            attribute vec2 aTex;
            uniform mat4 uMvp;
            varying vec2 vTex;
            void main() {
                gl_Position = aPos;
                vTex = (uMvp * vec4(aTex, 0.0, 1.0)).xy;
            }
        """.trimIndent()
        val fragmentShader = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            uniform samplerExternalOES uTex;
            uniform vec3 uColor;
            void main() {
                vec4 c = texture2D(uTex, vTex);
                gl_FragColor = vec4(c.rgb * vec3(1.0, 0.0, 0.0), 1.0);
            }
        """.trimIndent()
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexShader)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentShader)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vs)
        GLES20.glAttachShader(p, fs)
        GLES20.glLinkProgram(p)
        val status = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            android.util.Log.e("MiVBGSpike", "program link failed: ${GLES20.glGetProgramInfoLog(p)}")
        }
        program = p
        aPosLoc = GLES20.glGetAttribLocation(program, "aPos")
        aTexLoc = GLES20.glGetAttribLocation(program, "aTex")
        uMvpLoc = GLES20.glGetUniformLocation(program, "uMvp")
        uTexLoc = GLES20.glGetUniformLocation(program, "uTex")
        vertexBuffer = GlUtil.createFloatBuffer(vertices)
        texMatrixBuffer = GlUtil.createFloatBuffer(identity)
        android.util.Log.i("MiVBGSpike", "program=$program aPos=$aPosLoc aTex=$aTexLoc uMvp=$uMvpLoc uTex=$uTexLoc")
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            android.util.Log.e("MiVBGSpike", "shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}")
        }
        return shader
    }

    fun release() {
        yuvConverter.release()
    }
}
