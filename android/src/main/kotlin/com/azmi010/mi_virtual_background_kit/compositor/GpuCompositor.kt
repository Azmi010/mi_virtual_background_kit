package com.azmi010.mi_virtual_background_kit.compositor

import android.graphics.Matrix
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.util.Log
import com.azmi010.mi_virtual_background_kit.segmentation.PersonMask
import org.webrtc.GlUtil
import org.webrtc.RendererCommon
import org.webrtc.TextureBufferImpl
import org.webrtc.VideoFrame
import org.webrtc.YuvConverter
import java.nio.ByteBuffer
import java.nio.FloatBuffer

/**
 * Common interface for video frame compositors.
 */
interface FrameCompositor {
    val hasMask: Boolean
    val readbackWidth: Int
    val readbackHeight: Int
    fun readBackRgba(buffer: VideoFrame.TextureBuffer): ByteArray?
    fun uploadMask(mask: PersonMask)
    fun composeBlur(frame: VideoFrame, radius: Float): VideoFrame?
    fun release()
}

/**
 * OpenGL ES 2 GPU compositor for virtual background effects.
 *
 * Runs on the libwebrtc capture thread (which owns the shared EGL context).
 * In T3.3, composites a 3x3 box blur behind the person using the segmentation
 * mask produced by [com.azmi010.mi_virtual_background_kit.segmentation.Segmenter].
 */
class GpuCompositor : FrameCompositor {

    private val yuvConverter = YuvConverter()

    private var fbo = 0
    private var outTexture = 0
    private var outWidth = 0
    private var outHeight = 0

    // Vertex / texture coordinate buffers
    private var vertexBuffer: FloatBuffer? = null
    private var texCoordBuffer: FloatBuffer? = null

    // Readback program (renders camera texture into FBO so glReadPixels can extract CPU pixels)
    private var readbackProgramOes = 0
    private var rbOesAPos = 0
    private var rbOesATex = 0
    private var rbOesUMvp = 0
    private var rbOesUTex = 0

    private var readbackProgram2D = 0
    private var rb2dAPos = 0
    private var rb2dATex = 0
    private var rb2dUMvp = 0
    private var rb2dUTex = 0

    // Blur composite program (OES)
    private var blurProgramOes = 0
    private var blOesAPos = 0
    private var blOesATex = 0
    private var blOesUCamTransform = 0
    private var blOesUCamTex = 0
    private var blOesUMaskTex = 0
    private var blOesUTexelSize = 0
    private var blOesUTexelScale = 0

    // Blur composite program (2D)
    private var blurProgram2D = 0
    private var bl2dAPos = 0
    private var bl2dATex = 0
    private var bl2dUCamTransform = 0
    private var bl2dUCamTex = 0
    private var bl2dUMaskTex = 0
    private var bl2dUTexelSize = 0
    private var bl2dUTexelScale = 0

    // Mask texture
    private var maskTextureId = 0
    private var maskWidth = 0
    private var maskHeight = 0
    private var maskByteBuffer: ByteBuffer? = null

    // Readback buffer reuse
    private var readbackBuffer: ByteBuffer? = null
    private var readbackArray: ByteArray? = null

    override var readbackWidth: Int = 0
        private set
    override var readbackHeight: Int = 0
        private set

    override val hasMask: Boolean get() = maskTextureId != 0

    private val vertices = floatArrayOf(
        -1f, -1f,
        1f, -1f,
        -1f, 1f,
        1f, 1f,
    )

    private val texCoords = floatArrayOf(
        0f, 0f,
        1f, 0f,
        0f, 1f,
        1f, 1f,
    )

    private fun ensureBuffers() {
        if (vertexBuffer == null) vertexBuffer = GlUtil.createFloatBuffer(vertices)
        if (texCoordBuffer == null) texCoordBuffer = GlUtil.createFloatBuffer(texCoords)
    }

    /**
     * Reads camera texture back into a CPU RGBA byte array for person segmentation.
     * Must be called on the capture thread.
     */
    override fun readBackRgba(buffer: VideoFrame.TextureBuffer): ByteArray? {
        val width = buffer.unscaledWidth
        val height = buffer.unscaledHeight
        val isOes = buffer.type == VideoFrame.TextureBuffer.Type.OES
        val target = if (isOes) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D

        val size = width * height * 4
        if (readbackBuffer == null || readbackBuffer?.capacity() != size) {
            readbackBuffer = ByteBuffer.allocateDirect(size)
            readbackArray = ByteArray(size)
        }
        val outBuf = readbackBuffer ?: return null
        val outArr = readbackArray ?: return null
        outBuf.position(0)

        if (outWidth != width || outHeight != height) {
            createOutput(width, height)
        }

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glViewport(0, 0, width, height)

        if (isOes) {
            if (readbackProgramOes == 0) buildReadbackProgramOes()
            drawQuad(
                readbackProgramOes,
                rbOesAPos,
                rbOesATex,
                rbOesUMvp,
                rbOesUTex,
                target,
                buffer.textureId,
                convertMatrix(buffer.transformMatrix),
            )
        } else {
            if (readbackProgram2D == 0) buildReadbackProgram2D()
            drawQuad(
                readbackProgram2D,
                rb2dAPos,
                rb2dATex,
                rb2dUMvp,
                rb2dUTex,
                target,
                buffer.textureId,
                convertMatrix(buffer.transformMatrix),
            )
        }

        GLES20.glReadPixels(0, 0, width, height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, outBuf)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

        outBuf.position(0)
        outBuf.get(outArr)
        readbackWidth = width
        readbackHeight = height
        return outArr
    }

    /**
     * Uploads person segmentation [mask] to an OpenGL texture.
     * MaskCodec produces alpha bytes where 255 = person and 0 = background.
     */
    override fun uploadMask(mask: PersonMask) {
        val size = mask.width * mask.height
        if (maskByteBuffer == null || maskByteBuffer?.capacity() != size) {
            maskByteBuffer = ByteBuffer.allocateDirect(size)
        }
        val buf = maskByteBuffer ?: return
        buf.position(0)
        buf.put(mask.alpha, 0, size)
        buf.position(0)

        if (maskTextureId == 0) {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            maskTextureId = textures[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                mask.width, mask.height, 0,
                GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, buf,
            )
            maskWidth = mask.width
            maskHeight = mask.height
        } else {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
            if (maskWidth != mask.width || maskHeight != mask.height) {
                GLES20.glTexImage2D(
                    GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                    mask.width, mask.height, 0,
                    GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, buf,
                )
                maskWidth = mask.width
                maskHeight = mask.height
            } else {
                GLES20.glTexSubImage2D(
                    GLES20.GL_TEXTURE_2D, 0, 0, 0,
                    mask.width, mask.height,
                    GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, buf,
                )
            }
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
    }

    /**
     * Composites a blur effect behind the person in [frame].
     *
     * @param radius blur radius in [0, 100]. Mapped linearly via `radius / 25f`.
     */
    override fun composeBlur(frame: VideoFrame, radius: Float): VideoFrame? {
        val buffer = frame.buffer as? VideoFrame.TextureBuffer ?: return null
        if (maskTextureId == 0) return null

        val width = buffer.unscaledWidth
        val height = buffer.unscaledHeight
        val isOes = buffer.type == VideoFrame.TextureBuffer.Type.OES
        val target = if (isOes) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D

        if (outWidth != width || outHeight != height) {
            createOutput(width, height)
        }

        ensureBuffers()
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glViewport(0, 0, width, height)

        val texelScale = radius / 25.0f
        val texMatrix = convertMatrix(buffer.transformMatrix)

        if (isOes) {
            if (blurProgramOes == 0) buildBlurProgramOes()
            drawBlurQuad(
                blurProgramOes,
                blOesAPos,
                blOesATex,
                blOesUCamTransform,
                blOesUCamTex,
                blOesUMaskTex,
                blOesUTexelSize,
                blOesUTexelScale,
                target,
                buffer.textureId,
                maskTextureId,
                texMatrix,
                1.0f / width,
                1.0f / height,
                texelScale,
            )
        } else {
            if (blurProgram2D == 0) buildBlurProgram2D()
            drawBlurQuad(
                blurProgram2D,
                bl2dAPos,
                bl2dATex,
                bl2dUCamTransform,
                bl2dUCamTex,
                bl2dUMaskTex,
                bl2dUTexelSize,
                bl2dUTexelScale,
                target,
                buffer.textureId,
                maskTextureId,
                texMatrix,
                1.0f / width,
                1.0f / height,
                texelScale,
            )
        }

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

        val outBuffer = TextureBufferImpl(
            width,
            height,
            VideoFrame.TextureBuffer.Type.RGB,
            outTexture,
            Matrix(),
            null,
            yuvConverter,
            Runnable { },
        )
        return VideoFrame(outBuffer, frame.rotation, frame.timestampNs)
    }

    private fun createOutput(width: Int, height: Int) {
        if (fbo != 0) {
            val fbos = intArrayOf(fbo)
            GLES20.glDeleteFramebuffers(1, fbos, 0)
            fbo = 0
        }
        if (outTexture != 0) {
            val textures = intArrayOf(outTexture)
            GLES20.glDeleteTextures(1, textures, 0)
            outTexture = 0
        }

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
        if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
            Log.e(TAG, "FBO initialization failed, status=$status")
        }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

        outWidth = width
        outHeight = height
    }

    private fun drawQuad(
        program: Int,
        aPos: Int,
        aTex: Int,
        uMvp: Int,
        uTex: Int,
        target: Int,
        textureId: Int,
        texMatrix: FloatArray,
    ) {
        ensureBuffers()
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, textureId)
        GLES20.glUniform1i(uTex, 0)
        GLES20.glUniformMatrix4fv(uMvp, 1, false, texMatrix, 0)

        vertexBuffer?.position(0)
        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer)

        texCoordBuffer?.position(0)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, texCoordBuffer)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPos)
        GLES20.glDisableVertexAttribArray(aTex)
    }

    private fun drawBlurQuad(
        program: Int,
        aPos: Int,
        aTex: Int,
        uCamTransform: Int,
        uCamTex: Int,
        uMaskTex: Int,
        uTexelSize: Int,
        uTexelScale: Int,
        target: Int,
        camTextureId: Int,
        maskTextureId: Int,
        texMatrix: FloatArray,
        texelWidth: Float,
        texelHeight: Float,
        texelScale: Float,
    ) {
        ensureBuffers()
        GLES20.glUseProgram(program)

        // Camera texture -> unit 0
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, camTextureId)
        GLES20.glUniform1i(uCamTex, 0)

        // Mask texture -> unit 1
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
        GLES20.glUniform1i(uMaskTex, 1)

        GLES20.glUniformMatrix4fv(uCamTransform, 1, false, texMatrix, 0)
        GLES20.glUniform2f(uTexelSize, texelWidth, texelHeight)
        GLES20.glUniform1f(uTexelScale, texelScale)

        vertexBuffer?.position(0)
        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer)

        texCoordBuffer?.position(0)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, texCoordBuffer)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPos)
        GLES20.glDisableVertexAttribArray(aTex)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, 0)
    }

    private fun convertMatrix(matrix: Matrix?): FloatArray {
        if (matrix == null) {
            return floatArrayOf(
                1f, 0f, 0f, 0f,
                0f, 1f, 0f, 0f,
                0f, 0f, 1f, 0f,
                0f, 0f, 0f, 1f,
            )
        }
        return try {
            RendererCommon.convertMatrixFromAndroidGraphicsMatrix(matrix)
        } catch (_: Throwable) {
            val v = FloatArray(9)
            matrix.getValues(v)
            floatArrayOf(
                v[Matrix.MSCALE_X], v[Matrix.MSKEW_Y], 0f, v[Matrix.MPERSP_0],
                v[Matrix.MSKEW_X], v[Matrix.MSCALE_Y], 0f, v[Matrix.MPERSP_1],
                0f, 0f, 1f, 0f,
                v[Matrix.MTRANS_X], v[Matrix.MTRANS_Y], 0f, v[Matrix.MPERSP_2],
            )
        }
    }

    private fun buildReadbackProgramOes() {
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
            void main() {
                gl_FragColor = texture2D(uTex, vTex);
            }
        """.trimIndent()
        val p = linkProgram(vertexShader, fragmentShader)
        readbackProgramOes = p
        rbOesAPos = GLES20.glGetAttribLocation(p, "aPos")
        rbOesATex = GLES20.glGetAttribLocation(p, "aTex")
        rbOesUMvp = GLES20.glGetUniformLocation(p, "uMvp")
        rbOesUTex = GLES20.glGetUniformLocation(p, "uTex")
    }

    private fun buildReadbackProgram2D() {
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
            precision mediump float;
            varying vec2 vTex;
            uniform sampler2D uTex;
            void main() {
                gl_FragColor = texture2D(uTex, vTex);
            }
        """.trimIndent()
        val p = linkProgram(vertexShader, fragmentShader)
        readbackProgram2D = p
        rb2dAPos = GLES20.glGetAttribLocation(p, "aPos")
        rb2dATex = GLES20.glGetAttribLocation(p, "aTex")
        rb2dUMvp = GLES20.glGetUniformLocation(p, "uMvp")
        rb2dUTex = GLES20.glGetUniformLocation(p, "uTex")
    }

    private fun buildBlurProgramOes() {
        val vertexShader = """
            attribute vec4 aPos;
            attribute vec2 aTex;
            uniform mat4 uCamTransform;
            varying vec2 vCamTex;
            varying vec2 vMaskTex;
            void main() {
                gl_Position = aPos;
                vCamTex = (uCamTransform * vec4(aTex, 0.0, 1.0)).xy;
                vMaskTex = aTex;
            }
        """.trimIndent()
        val fragmentShader = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vCamTex;
            varying vec2 vMaskTex;
            uniform samplerExternalOES uCamTex;
            uniform sampler2D uMaskTex;
            uniform vec2 uTexelSize;
            uniform float uTexelScale;

            void main() {
                float personAlpha = texture2D(uMaskTex, vMaskTex).r;
                vec4 original = texture2D(uCamTex, vCamTex);

                vec4 blurSum = vec4(0.0);
                vec2 step = uTexelSize * uTexelScale;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        float w = 1.0;
                        if (dx == 0 && dy == 0) w = 4.0;
                        else if (dx == 0 || dy == 0) w = 2.0;
                        blurSum += texture2D(uCamTex, vCamTex + vec2(float(dx), float(dy)) * step) * w;
                    }
                }
                vec4 blurred = blurSum / 16.0;

                gl_FragColor = mix(blurred, original, personAlpha);
            }
        """.trimIndent()
        val p = linkProgram(vertexShader, fragmentShader)
        blurProgramOes = p
        blOesAPos = GLES20.glGetAttribLocation(p, "aPos")
        blOesATex = GLES20.glGetAttribLocation(p, "aTex")
        blOesUCamTransform = GLES20.glGetUniformLocation(p, "uCamTransform")
        blOesUCamTex = GLES20.glGetUniformLocation(p, "uCamTex")
        blOesUMaskTex = GLES20.glGetUniformLocation(p, "uMaskTex")
        blOesUTexelSize = GLES20.glGetUniformLocation(p, "uTexelSize")
        blOesUTexelScale = GLES20.glGetUniformLocation(p, "uTexelScale")
    }

    private fun buildBlurProgram2D() {
        val vertexShader = """
            attribute vec4 aPos;
            attribute vec2 aTex;
            uniform mat4 uCamTransform;
            varying vec2 vCamTex;
            varying vec2 vMaskTex;
            void main() {
                gl_Position = aPos;
                vCamTex = (uCamTransform * vec4(aTex, 0.0, 1.0)).xy;
                vMaskTex = aTex;
            }
        """.trimIndent()
        val fragmentShader = """
            precision mediump float;
            varying vec2 vCamTex;
            varying vec2 vMaskTex;
            uniform sampler2D uCamTex;
            uniform sampler2D uMaskTex;
            uniform vec2 uTexelSize;
            uniform float uTexelScale;

            void main() {
                float personAlpha = texture2D(uMaskTex, vMaskTex).r;
                vec4 original = texture2D(uCamTex, vCamTex);

                vec4 blurSum = vec4(0.0);
                vec2 step = uTexelSize * uTexelScale;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        float w = 1.0;
                        if (dx == 0 && dy == 0) w = 4.0;
                        else if (dx == 0 || dy == 0) w = 2.0;
                        blurSum += texture2D(uCamTex, vCamTex + vec2(float(dx), float(dy)) * step) * w;
                    }
                }
                vec4 blurred = blurSum / 16.0;

                gl_FragColor = mix(blurred, original, personAlpha);
            }
        """.trimIndent()
        val p = linkProgram(vertexShader, fragmentShader)
        blurProgram2D = p
        bl2dAPos = GLES20.glGetAttribLocation(p, "aPos")
        bl2dATex = GLES20.glGetAttribLocation(p, "aTex")
        bl2dUCamTransform = GLES20.glGetUniformLocation(p, "uCamTransform")
        bl2dUCamTex = GLES20.glGetUniformLocation(p, "uCamTex")
        bl2dUMaskTex = GLES20.glGetUniformLocation(p, "uMaskTex")
        bl2dUTexelSize = GLES20.glGetUniformLocation(p, "uTexelSize")
        bl2dUTexelScale = GLES20.glGetUniformLocation(p, "uTexelScale")
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            Log.e(TAG, "Shader compilation failed (type=$type): $log")
            return 0
        }
        return shader
    }

    private fun linkProgram(vertexSource: String, fragmentSource: String): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vs)
        GLES20.glAttachShader(program, fs)
        GLES20.glLinkProgram(program)
        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            Log.e(TAG, "Program link failed: $log")
            return 0
        }
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        return program
    }

    override fun release() {
        if (fbo != 0) {
            GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
            fbo = 0
        }
        if (outTexture != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(outTexture), 0)
            outTexture = 0
        }
        if (maskTextureId != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(maskTextureId), 0)
            maskTextureId = 0
        }
        if (readbackProgramOes != 0) {
            GLES20.glDeleteProgram(readbackProgramOes)
            readbackProgramOes = 0
        }
        if (readbackProgram2D != 0) {
            GLES20.glDeleteProgram(readbackProgram2D)
            readbackProgram2D = 0
        }
        if (blurProgramOes != 0) {
            GLES20.glDeleteProgram(blurProgramOes)
            blurProgramOes = 0
        }
        if (blurProgram2D != 0) {
            GLES20.glDeleteProgram(blurProgram2D)
            blurProgram2D = 0
        }
        yuvConverter.release()
    }

    companion object {
        private const val TAG = "MiVBGCompositor"
    }
}
