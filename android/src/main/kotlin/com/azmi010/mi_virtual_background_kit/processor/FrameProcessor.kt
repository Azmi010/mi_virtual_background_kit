package com.azmi010.mi_virtual_background_kit.processor

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.azmi010.mi_virtual_background_kit.compositor.FrameCompositor
import com.azmi010.mi_virtual_background_kit.compositor.GpuCompositor
import com.azmi010.mi_virtual_background_kit.segmentation.MaskSegmenter
import com.azmi010.mi_virtual_background_kit.segmentation.PersonMask
import com.azmi010.mi_virtual_background_kit.segmentation.Segmenter
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Frame processor for local camera tracks, installed at the flutter_webrtc
 * hook point (`LocalVideoTrack.addProcessor`, Android spike T0.4).
 *
 * Runs on the libwebrtc capture thread.
 *
 * In T3.4 (Blur, Image, and Solid Color Compositing):
 * - If no effect is active: passes frames through with zero overhead (FR-04).
 * - If an effect is active (Blur, Color, or Image):
 *   - Runs OpenGL ES 2 compositing via [FrameCompositor].
 *   - Throttles person segmentation to every [SEGMENT_EVERY_N_FRAMES] frames (~6 Hz at 30 fps)
 *     on a background worker thread, ensuring the capture thread is never blocked.
 *   - Uses the latest available person mask for compositing.
 */
class FrameProcessor(
    private val context: Context? = null,
    private val segmenterProvider: (() -> MaskSegmenter)? = null,
    private val compositorProvider: (() -> FrameCompositor)? = null,
    private val bitmapProvider: ((Int, Int) -> Bitmap)? = null,
) : LocalVideoTrack.ExternalVideoFrameProcessing {

    private val frames = AtomicInteger(0)
    val frameCount: Int get() = frames.get()

    @Volatile
    var lastRotation: Int = 0
        private set

    @Volatile
    var lastWidth: Int = 0
        private set

    @Volatile
    var lastHeight: Int = 0
        private set

    /** Currently active effect. Null means bypass (NoEffect). */
    sealed interface EffectState {
        data class Blur(val radius: Float) : EffectState
        data class Color(val color: Int) : EffectState
        data class Image(val bitmap: Bitmap, val fit: String) : EffectState
    }

    @Volatile
    var currentEffect: EffectState? = null
        private set

    // Compositor runs on capture thread
    private val compositor: FrameCompositor by lazy {
        compositorProvider?.invoke() ?: GpuCompositor()
    }

    // Segmenter runs on background executor
    private var segmenter: MaskSegmenter? = null
    private var segmenterInitialized = false

    private val segmentExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val isSegmenting = AtomicBoolean(false)

    @Volatile
    private var pendingMask: PersonMask? = null

    @Volatile
    private var pendingImageBitmap: Bitmap? = null

    /** Sets the blur effect with the given [radius] (in range (0, 100]). */
    fun setBlurEffect(radius: Float) {
        currentEffect = EffectState.Blur(radius)
        ensureSegmenter()
    }

    /** Sets the solid color background effect with [color] (32-bit ARGB). */
    fun setColorEffect(color: Int) {
        currentEffect = EffectState.Color(color)
        ensureSegmenter()
    }

    /** Sets the background image effect with [bitmap] and [fit] ("cover" or "contain"). */
    fun setImageEffect(bitmap: Bitmap, fit: String) {
        pendingImageBitmap = bitmap
        currentEffect = EffectState.Image(bitmap, fit)
        ensureSegmenter()
    }

    /** Clears any active effect, returning to pass-through (NoEffect). */
    fun clearEffect() {
        currentEffect = null
    }

    private fun ensureSegmenter() {
        if (!segmenterInitialized) {
            segmenterInitialized = true
            try {
                segmenter = segmenterProvider?.invoke()
                    ?: context?.let { Segmenter(it) }
            } catch (t: Throwable) {
                Log.e(TAG, "Failed to initialize Segmenter: $t")
                throw t
            }
        }
    }

    override fun onFrame(frame: VideoFrame): VideoFrame {
        val n = frames.incrementAndGet()
        lastRotation = frame.rotation
        lastWidth = frame.rotatedWidth
        lastHeight = frame.rotatedHeight
        val effect = currentEffect

        // Bypass when no effect is applied (FR-04)
        if (effect == null) {
            if (n == 1 || n % 150 == 0) {
                Log.i(
                    TAG,
                    "frame pass #$n ${frame.rotatedWidth}x${frame.rotatedHeight} " +
                        "rot=${frame.rotation} buffer=${frame.buffer.javaClass.simpleName}",
                )
            }
            return frame
        }

        val buffer = frame.buffer as? VideoFrame.TextureBuffer ?: return frame

        // 1. Upload pending background image if available
        val newImg = pendingImageBitmap
        if (newImg != null) {
            pendingImageBitmap = null
            try {
                compositor.uploadImage(newImg)
            } catch (t: Throwable) {
                Log.e(TAG, "Failed to upload background image to GPU: $t")
            }
        }

        // 2. Upload latest mask from segmentation worker if ready
        val mask = pendingMask
        if (mask != null) {
            pendingMask = null
            try {
                compositor.uploadMask(mask)
            } catch (t: Throwable) {
                Log.e(TAG, "Failed to upload mask to GPU: $t")
            }
        }

        // 3. Schedule segmentation every SEGMENT_EVERY_N_FRAMES if worker is idle
        if (n % SEGMENT_EVERY_N_FRAMES == 0 && isSegmenting.compareAndSet(false, true)) {
            val seg = segmenter
            if (seg != null) {
                val rgbaBytes = try {
                    compositor.readBackRgba(buffer)
                } catch (t: Throwable) {
                    Log.e(TAG, "Readback failed for segmentation: $t")
                    null
                }

                if (rgbaBytes != null) {
                    val w = compositor.readbackWidth
                    val h = compositor.readbackHeight
                    val bytesCopy = rgbaBytes.copyOf()
                    segmentExecutor.execute {
                        try {
                            val bmp = bitmapProvider?.invoke(w, h)
                                ?: Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                            try {
                                bmp.copyPixelsFromBuffer(ByteBuffer.wrap(bytesCopy))
                            } catch (_: Throwable) {
                                // Safe fallback in tests without native pixel backing
                            }
                            val resultMask = seg.segment(bmp)
                            pendingMask = PersonMask(
                                resultMask.alpha.copyOf(),
                                resultMask.width,
                                resultMask.height,
                            )
                            bmp.recycle()
                        } catch (t: Throwable) {
                            Log.e(TAG, "Background segmentation failed: $t")
                        } finally {
                            isSegmenting.set(false)
                        }
                    }
                } else {
                    isSegmenting.set(false)
                }
            } else {
                isSegmenting.set(false)
            }
        }

        // 4. Composite active effect if mask is available
        if (compositor.hasMask) {
            try {
                val composited = when (effect) {
                    is EffectState.Blur -> compositor.composeBlur(frame, effect.radius)
                    is EffectState.Color -> compositor.composeColor(frame, effect.color)
                    is EffectState.Image -> compositor.composeImage(frame, effect.fit)
                }
                if (composited != null) return composited
            } catch (t: Throwable) {
                Log.e(TAG, "Compositing failed: $t")
            }
        }

        // Fallback to original frame while mask is warming up or if compositing failed
        return frame
    }

    /** Releases all resources associated with this processor. */
    fun release() {
        clearEffect()
        segmentExecutor.shutdown()
        try {
            segmenter?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "Error closing segmenter: $t")
        }
        segmenter = null
        try {
            compositor.release()
        } catch (t: Throwable) {
            Log.w(TAG, "Error releasing compositor: $t")
        }
    }

    companion object {
        private const val TAG = "MiVBG"

        /**
         * Throttling interval for person segmentation: runs every 5 frames (~6 Hz at 30 fps).
         * Decision recorded in Phase 5 / T3.3.
         */
        const val SEGMENT_EVERY_N_FRAMES = 5
    }
}

/**
 * Installs [processor] on the flutter_webrtc local track with [trackId].
 *
 * ADR 0001 §1 contract: the returned [LocalVideoTrack] must be cached by the
 * caller — `stream.getMediaTracks()` from Dart replaces the registry entry
 * with a fresh object, so re-looking the track up by id afterwards attaches
 * to nothing (silent no-op).
 */
internal fun attachFrameProcessor(trackId: String, processor: FrameProcessor): LocalVideoTrack? {
    val plugin = com.cloudwebrtc.webrtc.FlutterWebRTCPlugin.sharedSingleton
        ?: return null
    val track = plugin.getLocalTrack(trackId)
    if (track !is LocalVideoTrack) return null
    track.addProcessor(processor)
    return track
}

/** Removes [processor] from [track]; no-op when either side is gone. */
internal fun detachFrameProcessor(track: LocalVideoTrack?, processor: FrameProcessor?) {
    if (track != null && processor != null) track.removeProcessor(processor)
}
