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
    var onStatusChange: ((String) -> Unit)? = null,
    var onFallbackEvent: ((Map<String, Any?>) -> Unit)? = null,
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

    // Reusable buffers to eliminate per-frame allocations during segmentation (T3.5)
    private var workerRgbaBuffer: ByteArray? = null
    private var workerByteBuffer: ByteBuffer? = null
    private var reusableBitmap: Bitmap? = null
    private var maskBufferA: ByteArray? = null
    private var maskBufferB: ByteArray? = null
    private var useMaskBufferA = true

    @Volatile
    var segmentationWidth: Int = 256
        private set

    @Volatile
    var edgeSmoothing: Float = 0.5f
        private set

    @Volatile
    var targetFps: Int = 30
        private set

    @Volatile
    var adaptiveSegmentInterval: Int = 3
        internal set

    @Volatile
    var isFallbackDisabled: Boolean = false
        internal set

    private var lastCompositedTimestampNs: Long = 0L

    // Performance window tracking (FR-12)
    private var windowStartTimestampNs: Long = 0L
    private var windowFrameCount: Int = 0
    private var lowFpsWindowCount: Int = 0
    private var lastFrameTimestampNs: Long = 0L

    /** Sets quality parameters controlling segmentation resolution, smoothing, and fps. */
    fun setQuality(segmentationWidth: Int, edgeSmoothing: Float, targetFps: Int) {
        this.segmentationWidth = segmentationWidth
        this.edgeSmoothing = edgeSmoothing.coerceIn(0.0f, 1.0f)
        this.targetFps = targetFps.coerceIn(1, 60)
        compositor.edgeSmoothing = this.edgeSmoothing
    }

    /** Sets the blur effect with the given [radius] (in range (0, 100]). */
    fun setBlurEffect(radius: Float) {
        isFallbackDisabled = false
        currentEffect = EffectState.Blur(radius)
        ensureSegmenter()
    }

    /** Sets the solid color background effect with [color] (32-bit ARGB). */
    fun setColorEffect(color: Int) {
        isFallbackDisabled = false
        currentEffect = EffectState.Color(color)
        ensureSegmenter()
    }

    /** Sets the background image effect with [bitmap] and [fit] ("cover" or "contain"). */
    fun setImageEffect(bitmap: Bitmap, fit: String) {
        isFallbackDisabled = false
        pendingImageBitmap = bitmap
        currentEffect = EffectState.Image(bitmap, fit)
        ensureSegmenter()
    }

    /** Clears any active effect, returning to pass-through (NoEffect). */
    fun clearEffect() {
        currentEffect = null
        pendingMask = null
        pendingImageBitmap = null
        lastCompositedTimestampNs = 0L
        windowStartTimestampNs = 0L
        windowFrameCount = 0
        lowFpsWindowCount = 0
        compositor.clearMask()
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

    private val isReleased = AtomicBoolean(false)

    override fun onFrame(frame: VideoFrame): VideoFrame {
        if (isReleased.get()) return frame
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

        val currentTimestamp = if (frame.timestampNs > 0) frame.timestampNs else System.nanoTime()

        // FR-09: background/foreground or camera restart leaves a multi-second
        // gap; a stale window would measure near-zero fps and falsely trip FR-12.
        if (lastFrameTimestampNs != 0L &&
            currentTimestamp - lastFrameTimestampNs > FRAME_GAP_RESET_NS
        ) {
            windowStartTimestampNs = 0L
            windowFrameCount = 0
            lowFpsWindowCount = 0
        }
        lastFrameTimestampNs = currentTimestamp

        // FR-12: Monitor frame rate across sliding window and evaluate performance fallback
        if (windowStartTimestampNs == 0L) {
            windowStartTimestampNs = currentTimestamp
            windowFrameCount = 0
        } else {
            windowFrameCount++
            if (windowFrameCount >= FPS_MONITOR_WINDOW_FRAMES) {
                val elapsedSec = (currentTimestamp - windowStartTimestampNs) / 1_000_000_000.0
                if (elapsedSec > 0.0) {
                    val measuredFps = windowFrameCount / elapsedSec
                    evaluatePerformance(measuredFps)
                }
                windowStartTimestampNs = currentTimestamp
                windowFrameCount = 0
            }
        }

        if (targetFps < 30 && lastCompositedTimestampNs > 0L) {
            val elapsed = currentTimestamp - lastCompositedTimestampNs
            val minIntervalNs = 1_000_000_000L / targetFps
            if (elapsed < (minIntervalNs * 85 / 100)) {
                val reused = compositor.reuseLastFrame(frame)
                if (reused != null) {
                    return reused
                }
            }
        }

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

        // 3. Schedule segmentation adaptively (or immediately on first frame) if worker is idle
        val interval = adaptiveSegmentInterval
        if ((!compositor.hasMask || n % interval == 0) && isSegmenting.compareAndSet(false, true)) {
            val seg = segmenter
            if (seg != null) {
                val rgbaBytes = try {
                    compositor.readBackRgba(buffer, segmentationWidth)
                } catch (t: Throwable) {
                    Log.e(TAG, "Readback failed for segmentation: $t")
                    null
                }

                if (rgbaBytes != null) {
                    val w = compositor.readbackWidth
                    val h = compositor.readbackHeight
                    val size = rgbaBytes.size
                    if (workerRgbaBuffer == null || workerRgbaBuffer!!.size != size) {
                        workerRgbaBuffer = ByteArray(size)
                        workerByteBuffer = ByteBuffer.wrap(workerRgbaBuffer!!)
                    }
                    val dest = workerRgbaBuffer!!
                    System.arraycopy(rgbaBytes, 0, dest, 0, size)

                    segmentExecutor.execute {
                        try {
                            val bmp = bitmapProvider?.invoke(w, h) ?: run {
                                var b = reusableBitmap
                                if (b == null || b.width != w || b.height != h) {
                                    b?.recycle()
                                    b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                                    reusableBitmap = b
                                }
                                b
                            }
                            try {
                                val bb = workerByteBuffer
                                bb?.position(0)
                                if (bb != null) {
                                    bmp.copyPixelsFromBuffer(bb)
                                }
                            } catch (_: Throwable) {
                                // Safe fallback in tests without native pixel backing
                            }
                            val startInferenceNs = System.nanoTime()
                            val resultMask = seg.segment(bmp)
                            val inferenceMs = (System.nanoTime() - startInferenceNs) / 1_000_000

                            // Adaptively update interval: fast hardware tracks at ~15 Hz, slower at ~6 or ~3 Hz
                            adaptiveSegmentInterval = when {
                                inferenceMs < 25 -> 2
                                inferenceMs <= 50 -> 3
                                inferenceMs <= 85 -> 5
                                inferenceMs <= 150 -> 8
                                else -> 10
                            }

                            val maskSize = resultMask.width * resultMask.height
                            val targetBuf = if (useMaskBufferA) {
                                if (maskBufferA == null || maskBufferA!!.size != maskSize) {
                                    maskBufferA = ByteArray(maskSize)
                                }
                                useMaskBufferA = false
                                maskBufferA!!
                            } else {
                                if (maskBufferB == null || maskBufferB!!.size != maskSize) {
                                    maskBufferB = ByteArray(maskSize)
                                }
                                useMaskBufferA = true
                                maskBufferB!!
                            }
                            System.arraycopy(resultMask.alpha, 0, targetBuf, 0, maskSize)
                            pendingMask = PersonMask(
                                targetBuf,
                                resultMask.width,
                                resultMask.height,
                            )
                        } catch (t: Throwable) {
                            Log.e(TAG, "Background segmentation failed: $t")
                            onStatusChange?.invoke("error")
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
                if (composited != null) {
                    lastCompositedTimestampNs = currentTimestamp
                    return composited
                }
            } catch (t: Throwable) {
                Log.e(TAG, "Compositing failed: $t")
            }
        }

        // Fallback to original frame while mask is warming up or if compositing failed
        return frame
    }

    /** Releases all resources associated with this processor. Idempotent. */
    fun release() {
        if (!isReleased.compareAndSet(false, true)) return
        clearEffect()
        segmentExecutor.shutdown()
        try {
            segmentExecutor.awaitTermination(200, java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (_: Throwable) {
            segmentExecutor.shutdownNow()
        }
        try {
            segmenter?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "Error closing segmenter: $t")
        }
        segmenter = null
        reusableBitmap?.recycle()
        reusableBitmap = null
        workerRgbaBuffer = null
        workerByteBuffer = null
        maskBufferA = null
        maskBufferB = null
        try {
            compositor.release()
        } catch (t: Throwable) {
            Log.w(TAG, "Error releasing compositor: $t")
        }
    }

    internal fun evaluatePerformance(measuredFps: Double) {
        if (currentEffect == null || isReleased.get()) return

        if (measuredFps < DEGRADE_FPS_THRESHOLD) {
            lowFpsWindowCount++
            if (segmentationWidth > 192) {
                val oldWidth = segmentationWidth
                segmentationWidth = 192
                adaptiveSegmentInterval = (adaptiveSegmentInterval + 2).coerceAtMost(MAX_SEGMENT_INTERVAL)
                Log.w(TAG, "Performance drop detected: fps=$measuredFps < $DEGRADE_FPS_THRESHOLD. Degraded resolution $oldWidth -> 192")
                onFallbackEvent?.invoke(
                    mapOf(
                        "event" to "fallback",
                        "action" to "qualityDegraded",
                        "reason" to "fps_drop_${String.format(java.util.Locale.US, "%.1f", measuredFps)}",
                        "segmentationWidth" to 192,
                        "targetFps" to targetFps,
                    )
                )
            } else if (measuredFps < CRITICAL_LOW_FPS && lowFpsWindowCount >= 2) {
                isFallbackDisabled = true
                clearEffect()
                Log.e(TAG, "Critical performance drop: fps=$measuredFps < $CRITICAL_LOW_FPS. Auto-disabled effect.")
                onStatusChange?.invoke("idle")
                onFallbackEvent?.invoke(
                    mapOf(
                        "event" to "fallback",
                        "action" to "disabled",
                        "reason" to "fps_critical_${String.format(java.util.Locale.US, "%.1f", measuredFps)}",
                    )
                )
            }
        } else {
            lowFpsWindowCount = 0
        }
    }

    /** Allows simulating a performance drop directly for unit testing (FR-12). */
    internal fun simulatePerformanceDrop(measuredFps: Double) {
        evaluatePerformance(measuredFps)
    }

    companion object {
        private const val TAG = "MiVBG"

        /**
         * Throttling interval for person segmentation: runs every 5 frames (~6 Hz at 30 fps).
         * Decision recorded in Phase 5 / T3.3.
         */
        const val SEGMENT_EVERY_N_FRAMES = 5
        const val MIN_SEGMENT_INTERVAL = 2
        const val MAX_SEGMENT_INTERVAL = 10
        const val FPS_MONITOR_WINDOW_FRAMES = 45
        const val DEGRADE_FPS_THRESHOLD = 14
        const val CRITICAL_LOW_FPS = 10
        const val FRAME_GAP_RESET_NS = 1_000_000_000L
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
    val registry = plugin.getLocalTrack(trackId)
    if (registry !is LocalVideoTrack) return null
    // T14.1 (ADR 0002 §6): install on the wrapper the VideoSource actually
    // feeds — a shared track or a registry replacement leaves `registry`
    // without frames, so addProcessor there would silently never run.
    val target = resolveWiredTrack(trackId, registry).target
    target.addProcessor(processor)
    return target
}

/** Removes [processor] from [track]; no-op when either side is gone. */
internal fun detachFrameProcessor(track: LocalVideoTrack?, processor: FrameProcessor?) {
    if (track != null && processor != null) track.removeProcessor(processor)
}
