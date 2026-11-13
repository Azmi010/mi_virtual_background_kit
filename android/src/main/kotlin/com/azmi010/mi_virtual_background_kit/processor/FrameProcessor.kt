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

    // T14.5 measurement hook: overrides the bundled model asset (null =
    // production MODEL_ASSET). The example's T14.5 page A/Bs landscape
    // against the legacy square model; not public API.
    @Volatile
    private var testModelAsset: String? = null

    /** Asset the current [segmenter] instance was built from. */
    @Volatile
    private var segmenterAssetInUse: String? = null

    /** Last inference duration reported by the segmentation worker, ms. */
    @Volatile
    private var lastInferenceMs: Long = -1

    /** Capture-thread only: of the previously logged mask, ns (gap metric). */
    private var lastMaskLogNs: Long = 0

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

    // T14.2 (FR-20): temporal mask smoothing at mask upload (ADR 0002 §7).
    // 0 = raw upload, identical to v0.1.
    @Volatile
    var maskTemporalSmoothing: Float = 0.7f
        private set

    private val maskSmoother = MaskTemporalSmoother()

    // T14.2/T14.3 measurement hooks: non-null mode overrides production
    // smoothing from the example's flicker-test page (not public API).
    @Volatile
    private var testSmoothingMode: String? = null

    @Volatile
    private var testSmoothingValue: Float = 0f

    @Volatile
    private var testSmoothingD0: Float = MaskTemporalSmoother.ADAPTIVE_D0

    @Volatile
    private var testStage: String = "-"

    private var fpsLogNs: Long = 0L
    private var fpsLogFrames: Int = 0
    private var fpsLogValue: Double = 0.0

    @Volatile
    var adaptiveSegmentInterval: Int = 3
        internal set

    @Volatile
    var isFallbackDisabled: Boolean = false
        internal set

    // T14.4 (FR-21): fallback recovery state.
    /** Whether `BackgroundQuality.autoRecovery` is enabled (opt-in). */
    @Volatile
    internal var autoRecovery: Boolean = false

    /** Last user-configured segmentation width; stage-1 restore target. */
    @Volatile
    private var configuredWidth: Int = 256

    /** Effect stashed when stage-2 disabled the pipeline; restored on resume. */
    @Volatile
    private var stashedEffect: EffectState? = null

    /**
     * One-shot latch: cleared when auto-recovery re-enables the effect, set
     * again only by a manual setEffect/setQuality. A device that cannot keep
     * up then stays disabled instead of flapping (PRD "tanpa osilasi").
     */
    @Volatile
    private var autoRecoveryArmed: Boolean = true

    /** Consecutive healthy fps windows; drives both recovery paths. */
    private var healthyFpsWindowCount: Int = 0

    /** True after auto-resume until the first frame composites (FR-21 status). */
    @Volatile
    private var awaitingActiveAfterResume: Boolean = false

    private var lastCompositedTimestampNs: Long = 0L

    // Performance window tracking (FR-12)
    private var windowStartTimestampNs: Long = 0L
    private var windowFrameCount: Int = 0
    private var lowFpsWindowCount: Int = 0
    private var lastFrameTimestampNs: Long = 0L

    /** Sets quality parameters controlling segmentation resolution, smoothing, and fps. */
    fun setQuality(
        segmentationWidth: Int,
        edgeSmoothing: Float,
        targetFps: Int,
        maskTemporalSmoothing: Float = 0.7f,
        autoRecovery: Boolean = false,
    ) {
        this.configuredWidth = segmentationWidth
        this.segmentationWidth = segmentationWidth
        this.edgeSmoothing = edgeSmoothing.coerceIn(0.0f, 1.0f)
        this.targetFps = targetFps.coerceIn(1, 60)
        this.maskTemporalSmoothing = maskTemporalSmoothing.coerceIn(0.0f, 1.0f)
        this.autoRecovery = autoRecovery
        // A quality change is a manual intervention: re-arm auto-recovery (FR-21).
        this.autoRecoveryArmed = true
        compositor.edgeSmoothing = this.edgeSmoothing
        maskSmoother.reset()
    }

    /**
     * T14.2/T14.3 measurement hook: overrides mask smoothing
     * (`mode`: `none`/`ema`/`adaptive`; `d0` null = default) and resets the
     * history. Null mode resumes production smoothing from [setQuality].
     */
    fun setTestSmoothing(mode: String?, value: Float, d0: Float?) {
        testSmoothingMode = mode
        testSmoothingValue = value.coerceIn(0.0f, 1.0f)
        testSmoothingD0 = d0 ?: MaskTemporalSmoother.ADAPTIVE_D0
        maskSmoother.reset()
    }

    /** T14.2/T14.3 measurement hook: tags `T133|` lines and resets history. */
    fun setTestStage(stage: String) {
        testStage = stage
        maskSmoother.reset()
    }

    /**
     * Adopts a user-chosen effect: leaves the fallback-disabled state, drops
     * the stashed effect, and re-arms auto-recovery (manual intervention,
     * FR-21). Returns true when this re-enabled an effect stage-2 disabled.
     */
    private fun adoptManualEffect(effect: EffectState): Boolean {
        val wasFallbackDisabled = isFallbackDisabled
        isFallbackDisabled = false
        stashedEffect = null
        autoRecoveryArmed = true
        awaitingActiveAfterResume = false
        currentEffect = effect
        return wasFallbackDisabled
    }

    /** Sets the blur effect with the given [radius] (in range (0, 100]). */
    fun setBlurEffect(radius: Float) {
        val resumed = adoptManualEffect(EffectState.Blur(radius))
        ensureSegmenter()
        if (resumed) emitRecovered("manual")
    }

    /** Sets the solid color background effect with [color] (32-bit ARGB). */
    fun setColorEffect(color: Int) {
        val resumed = adoptManualEffect(EffectState.Color(color))
        ensureSegmenter()
        if (resumed) emitRecovered("manual")
    }

    /** Sets the background image effect with [bitmap] and [fit] ("cover" or "contain"). */
    fun setImageEffect(bitmap: Bitmap, fit: String) {
        pendingImageBitmap = bitmap
        val resumed = adoptManualEffect(EffectState.Image(bitmap, fit))
        ensureSegmenter()
        if (resumed) emitRecovered("manual")
    }

    /** Clears any active effect, returning to pass-through (NoEffect). */
    fun clearEffect() {
        // User chose no effect: cancel any pending fallback recovery (FR-21).
        isFallbackDisabled = false
        stashedEffect = null
        awaitingActiveAfterResume = false
        resetEffectState()
    }

    /**
     * Nulls the active effect and resets the performance windows. Leaves the
     * fallback flags alone: stage-2 stashes the effect and sets
     * `isFallbackDisabled` before calling this.
     */
    private fun resetEffectState() {
        currentEffect = null
        pendingMask = null
        pendingImageBitmap = null
        lastCompositedTimestampNs = 0L
        windowStartTimestampNs = 0L
        windowFrameCount = 0
        lowFpsWindowCount = 0
        healthyFpsWindowCount = 0
        awaitingActiveAfterResume = false
        maskSmoother.reset()
        compositor.clearMask()
    }

    /**
     * Ensures a segmenter exists for the wanted model asset. Switching
     * [testModelAsset] closes the old instance on the segment worker (never
     * mid-inference) and builds a fresh one on the next call.
     */
    private fun ensureSegmenter() {
        val wanted = testModelAsset ?: Segmenter.MODEL_ASSET
        if (segmenterInitialized && segmenterAssetInUse == wanted) return
        if (segmenterInitialized) {
            // Close on the segment worker so a running segment() finishes first.
            try {
                segmentExecutor.submit {
                    try {
                        segmenter?.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "Error closing segmenter: $t")
                    }
                    segmenter = null
                }.get(2, java.util.concurrent.TimeUnit.SECONDS)
            } catch (t: Throwable) {
                Log.w(TAG, "Segmenter close did not finish cleanly: $t")
            }
            segmenterInitialized = false
        }
        segmenterInitialized = true
        try {
            segmenter = segmenterProvider?.invoke()
                ?: context?.let { Segmenter(it, wanted) }
            segmenterAssetInUse = wanted
        } catch (t: Throwable) {
            segmenterInitialized = false
            segmenterAssetInUse = null
            Log.e(TAG, "Failed to initialize Segmenter: $t")
            throw t
        }
    }

    /**
     * T14.5 measurement hook: selects the model asset (`null` = production
     * [Segmenter.MODEL_ASSET]) and rebuilds the segmenter. Not public API.
     */
    fun setTestModel(modelAsset: String?) {
        testModelAsset = modelAsset
        ensureSegmenter()
        Log.i(TAG, "T145| SET_MODEL model=${modelAsset ?: Segmenter.MODEL_ASSET}")
    }

    private val isReleased = AtomicBoolean(false)

    override fun onFrame(frame: VideoFrame): VideoFrame {
        if (isReleased.get()) return frame
        val n = frames.incrementAndGet()
        lastRotation = frame.rotation
        lastWidth = frame.rotatedWidth
        lastHeight = frame.rotatedHeight
        val effect = currentEffect

        val buffer = frame.buffer as? VideoFrame.TextureBuffer
        val currentTimestamp = if (frame.timestampNs > 0) frame.timestampNs else System.nanoTime()

        // FR-12/FR-21: monitor fps while an effect is active, or while a
        // stage-2 fallback watches for auto-recovery.
        if (effect != null || (isFallbackDisabled && autoRecovery)) {
            // FR-09: background/foreground or camera restart leaves a multi-second
            // gap; a stale window would measure near-zero fps and falsely trip FR-12.
            if (lastFrameTimestampNs != 0L &&
                currentTimestamp - lastFrameTimestampNs > FRAME_GAP_RESET_NS
            ) {
                windowStartTimestampNs = 0L
                windowFrameCount = 0
                lowFpsWindowCount = 0
                healthyFpsWindowCount = 0
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
        }

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

        if (buffer == null) return frame

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
                uploadMaskWithSmoothing(mask)
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
                            lastInferenceMs = inferenceMs

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
                    if (awaitingActiveAfterResume) {
                        awaitingActiveAfterResume = false
                        onStatusChange?.invoke("active")
                    }
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
        if (isReleased.get()) return

        // FR-21: while bypassed by stage-2, watch for stable fps to auto-resume.
        if (isFallbackDisabled) {
            if (!autoRecovery || !autoRecoveryArmed ||
                measuredFps < RECOVER_FPS_THRESHOLD
            ) {
                healthyFpsWindowCount = 0
                return
            }
            healthyFpsWindowCount++
            if (healthyFpsWindowCount >= RECOVERY_STABLE_WINDOWS) {
                // One shot: if the device fails again it stays disabled until
                // a manual setEffect/setQuality re-arms (PRD "tanpa osilasi").
                autoRecoveryArmed = false
                resumeFromFallback("auto")
            }
            return
        }

        // User chose no effect: nothing to monitor (FR-04).
        if (currentEffect == null) return

        if (measuredFps < DEGRADE_FPS_THRESHOLD) {
            healthyFpsWindowCount = 0
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
                // Stage 2: stash the effect before clearing so FR-21 can restore it.
                stashedEffect = currentEffect
                isFallbackDisabled = true
                resetEffectState()
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
            // FR-21 hysteresis: restore the configured quality only after fps
            // stays >= RECOVER_FPS_THRESHOLD (dead band between 14 and 20).
            if (autoRecovery && measuredFps >= RECOVER_FPS_THRESHOLD) {
                healthyFpsWindowCount++
                if (healthyFpsWindowCount >= RECOVERY_STABLE_WINDOWS &&
                    segmentationWidth != configuredWidth
                ) {
                    segmentationWidth = configuredWidth
                    healthyFpsWindowCount = 0
                    Log.i(TAG, "T144| quality restored width=$segmentationWidth fps=$measuredFps")
                    emitRecovered("auto_quality")
                }
            } else {
                healthyFpsWindowCount = 0
            }
        }
    }

    /**
     * Restores the effect stashed by stage-2 (FR-21). Emits `recovered`,
     * then status `initializing`; the first composited frame emits `active`
     * (PRD: disabled -> initializing -> active).
     */
    private fun resumeFromFallback(reason: String) {
        val stash = stashedEffect
        isFallbackDisabled = false
        stashedEffect = null
        healthyFpsWindowCount = 0
        lowFpsWindowCount = 0
        windowStartTimestampNs = 0L
        windowFrameCount = 0
        if (segmentationWidth != configuredWidth) {
            segmentationWidth = configuredWidth
        }
        // Non-null: stage-2 only disables while an effect is active.
        currentEffect = stash
        awaitingActiveAfterResume = true
        Log.i(TAG, "T144| recovered reason=$reason width=$segmentationWidth")
        emitRecovered(reason)
        onStatusChange?.invoke("initializing")
    }

    private fun emitRecovered(reason: String) {
        onFallbackEvent?.invoke(
            mapOf(
                "event" to "fallback",
                "action" to "recovered",
                "reason" to reason,
                "segmentationWidth" to segmentationWidth,
                "targetFps" to targetFps,
            )
        )
    }

    /**
     * T14.2: uploads the mask, temporal-smoothing it first (ADR 0002 §7), and
     * emits one `T133|` metric line per mask while smoothing is active.
     * `maskTemporalSmoothing == 0` uploads the raw mask (identical to v0.1).
     */
    private fun uploadMaskWithSmoothing(mask: PersonMask) {
        val hookMode = testSmoothingMode
        val mode = hookMode ?: "adaptive"
        val value = if (hookMode != null) testSmoothingValue else maskTemporalSmoothing
        if (hookMode == null && value <= 0f) {
            maskSmoother.reset()
            compositor.uploadMask(mask)
            return
        }
        val d0 = if (hookMode != null) testSmoothingD0 else MaskTemporalSmoother.ADAPTIVE_D0
        val res = maskSmoother.process(mask.alpha, mode, value, d0)
        logMaskMetrics(res, mode, value, d0)
        compositor.uploadMask(PersonMask(res.alpha, mask.width, mask.height))
    }

    /** One metric line per smoothed mask; parsed by tool/smoothing_metrics.py. */
    private fun logMaskMetrics(
        res: MaskTemporalSmoother.Result,
        mode: String,
        value: Float,
        d0: Float,
    ) {
        val now = System.nanoTime()
        // T14.5 freshness metrics: gap since the previous logged mask,
        // last inference cost, and the live adaptive scheduling interval.
        val gap = if (lastMaskLogNs == 0L) -1 else (now - lastMaskLogNs) / 1_000_000
        lastMaskLogNs = now
        if (fpsLogNs == 0L) {
            fpsLogNs = now
            fpsLogFrames = frames.get()
        } else if (now - fpsLogNs >= 1_000_000_000L) {
            fpsLogValue = (frames.get() - fpsLogFrames) * 1_000_000_000.0 / (now - fpsLogNs)
            fpsLogNs = now
            fpsLogFrames = frames.get()
        }
        Log.i(
            TAG,
            "T133| m=$mode v=${fmt(value, 2)} d0=${fmt(d0, 2)} st=$testStage " +
                "rev=${res.rev} chg=${res.chg} d=${fmt(res.dPct, 1)} lag=${fmt(res.lagPct, 1)} " +
                "px=${res.alpha.size} us=${res.us} fps=${fmt(fpsLogValue, 1)} " +
                "gap=$gap inf=$lastInferenceMs iv=$adaptiveSegmentInterval",
        )
    }

    private fun fmt(v: Number, digits: Int): String =
        String.format(java.util.Locale.US, "%.${digits}f", v)

    /** Allows simulating a performance window directly for tests (FR-12/FR-21). */
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

        /** FR-21: fps must stay >= this for [RECOVERY_STABLE_WINDOWS] to recover. */
        const val RECOVER_FPS_THRESHOLD = 20
        const val RECOVERY_STABLE_WINDOWS = 2
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
