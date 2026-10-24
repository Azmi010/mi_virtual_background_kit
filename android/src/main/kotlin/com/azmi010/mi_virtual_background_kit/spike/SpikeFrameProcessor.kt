package com.azmi010.mi_virtual_background_kit.spike

import com.cloudwebrtc.webrtc.LocalTrack
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger

/**
 * Spike T0.4: prove that a frame processor can be installed on a local camera
 * track created by flutter_webrtc and that transformed frames reach the
 * renderer.
 *
 * The transform inverts the U and V planes of an I420 frame, which produces a
 * visible colour shift in the preview.
 */
class SpikeFrameProcessor(
    private val transform: (VideoFrame) -> VideoFrame = { it },
) : LocalVideoTrack.ExternalVideoFrameProcessing {
    private val frames = AtomicInteger(0)

    @Volatile
    var enabled: Boolean = true

    val frameCount: Int get() = frames.get()

    /** Buffer class name of the first frame seen, e.g. "WrappedNativeI420Buffer". */
    @Volatile
    var bufferType: String? = null
        private set

    /** Rotation reported by the first frame seen. */
    @Volatile
    var rotation: Int = 0
        private set

    @Volatile
    var width: Int = 0
        private set

    @Volatile
    var height: Int = 0
        private set

    override fun onFrame(frame: VideoFrame): VideoFrame {
        arrivals.incrementAndGet()
        fulfillReadbackIfNeeded(frame)
        fulfillImageIfNeeded()
        if (!enabled) return frame
        frames.incrementAndGet()
        lastFrame = frame
        if (bufferType == null) {
            bufferType = frame.buffer.javaClass.name
            rotation = frame.rotation
            width = frame.rotatedWidth
            height = frame.rotatedHeight
            android.util.Log.i(
                "MiVBGSpike",
                "first frame buffer=${bufferType} rot=$rotation size=${width}x${height}",
            )
        }
        if (benchmarkReadback) {
            benchmarkReadback = false
            try {
                val t0 = System.nanoTime()
                val i420 = frame.buffer.toI420()
                val t1 = System.nanoTime()
                android.util.Log.i(
                    "MiVBGSpike",
                    "toI420 took ${(t1 - t0) / 1000} us size=${i420?.width}x${i420?.height}",
                )
            } catch (t: Throwable) {
                android.util.Log.e("MiVBGSpike", "toI420 failed: $t")
            }
        }
        return try {
            val gpu = compositor
            if (gpu != null) {
                gpu.compose(frame, compositeColor) ?: transform(frame)
            } else {
                transform(frame)
            }
        } catch (t: Throwable) {
            android.util.Log.e("MiVBGSpike", "transform failed: $t")
            frame
        }
    }

    @Volatile
    var benchmarkReadback: Boolean = false

    /** Optional GPU compositor used instead of the plain transform. */
    @Volatile
    var compositor: SpikeGpuCompositor? = null

    // --- Readback from the capture thread -----------------------------------
    //
    // glReadPixels only works on the thread that owns the EGL context, i.e. the
    // capture thread that runs onFrame. Main-thread reads return an all-zero
    // buffer. The method channel sets readbackRequest, the next frame fulfils
    // it, and the caller waits on the latch.

    @Volatile
    private var readbackRequest = false

    @Volatile
    var readbackBytes: ByteArray? = null
        private set

    @Volatile
    private var readbackLatch: java.util.concurrent.CountDownLatch? = null

    // Frames seen per second regardless of effect state — benchmark FPS source.
    private val arrivals = java.util.concurrent.atomic.AtomicInteger(0)
    val arrivalCount: Int get() = arrivals.get()

    /** [Triple] of (rgbaBytes, width, height) waiting for capture-thread upload. */
    @Volatile
    private var imageRequest: Triple<ByteArray, Int, Int>? = null

    @Volatile
    private var imageLatch: java.util.concurrent.CountDownLatch? = null

    /** Uploads the effect image to GL. Blocks the caller until capture runs. */
    fun requestImage(bytes: ByteArray, width: Int, height: Int, timeoutMs: Long = 3000): Boolean {
        val latch = java.util.concurrent.CountDownLatch(1)
        imageRequest = Triple(bytes, width, height)
        imageLatch = latch
        return latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
    }

    private fun fulfillImageIfNeeded() {
        val req = imageRequest ?: return
        imageRequest = null
        try {
            compositor?.uploadImage(req.first, req.second, req.third)
        } catch (t: Throwable) {
            android.util.Log.e("MiVBGSpike", "image upload failed: $t")
        }
        imageLatch?.countDown()
    }

    /** Asks the capture thread to read the current frame back. Blocks the caller. */
    fun requestReadback(timeoutMs: Long = 3000): Boolean {
        readbackBytes = null
        val latch = java.util.concurrent.CountDownLatch(1)
        readbackLatch = latch
        readbackRequest = true
        return latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
    }

    private fun fulfillReadbackIfNeeded(frame: VideoFrame) {
        if (!readbackRequest) return
        readbackRequest = false
        val gpu = compositor
        val texture = frame.buffer as? VideoFrame.TextureBuffer
        var bytes: ByteArray? = null
        if (gpu != null && texture != null) {
            try {
                bytes = gpu.readBackRgba(texture)
            } catch (t: Throwable) {
                android.util.Log.e("MiVBGSpike", "readback failed: $t")
            }
        }
        if (bytes != null) readbackBytes = bytes
        readbackLatch?.countDown()
    }

    @Volatile
    var compositeColor: FloatArray = floatArrayOf(0.1f, 0.4f, 0.9f)

    /** The most recent frame seen, used for one-off benchmarks. */
    @Volatile
    var lastFrame: VideoFrame? = null
        private set
}

/** Installs [processor] on the flutter_webrtc local track with [trackId]. */
object SpikeHook {
    fun attach(trackId: String, processor: SpikeFrameProcessor): Boolean {
        val plugin = com.cloudwebrtc.webrtc.FlutterWebRTCPlugin.sharedSingleton ?: return false
        val track: LocalTrack? = plugin.getLocalTrack(trackId)
        if (track !is LocalVideoTrack) return false
        track.addProcessor(processor)
        return true
    }

    fun detach(trackId: String, processor: SpikeFrameProcessor): Boolean {
        val plugin = com.cloudwebrtc.webrtc.FlutterWebRTCPlugin.sharedSingleton ?: return false
        val track: LocalTrack? = plugin.getLocalTrack(trackId)
        if (track !is LocalVideoTrack) return false
        track.removeProcessor(processor)
        return true
    }
}

/**
 * Inverts the chroma planes of an I420 frame in place.
 *
 * Returns null when the frame buffer is not a CPU-side I420 buffer, in which
 * case the frame must be left untouched.
 */
object SpikeInvert {
    fun apply(frame: VideoFrame): VideoFrame {
        val buffer = frame.buffer
        if (buffer !is VideoFrame.I420Buffer) return frame
        val width = buffer.getWidth()
        invert(buffer.dataU, buffer.strideU, width)
        invert(buffer.dataV, buffer.strideV, width)
        return frame
    }

    private fun invert(data: ByteBuffer, stride: Int, width: Int) {
        val rowBytes = width / 2
        val rows = width / 2
        for (row in 0 until rows) {
            val offset = row * stride
            for (i in 0 until rowBytes) {
                val index = offset + i
                if (index >= data.limit()) continue
                data.put(index, (0xFF - data.get(index).toInt()).toByte())
            }
        }
    }
}
