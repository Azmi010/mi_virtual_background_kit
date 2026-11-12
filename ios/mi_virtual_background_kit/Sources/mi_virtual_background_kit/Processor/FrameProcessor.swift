import Foundation
import UIKit
import WebRTC
import flutter_webrtc

/// Frame processor for local camera tracks installed on flutter_webrtc's
/// `LocalVideoTrack.addProcessing(_:)` hook point (ADR 0001 §1).
///
/// Runs on the WebRTC capture/encoder thread.
///
/// In T4.3:
/// - Passthrough with zero overhead when no effect is applied (FR-04).
/// - Metal and Core Image GPU compositing for Blur, Color, and Image effects.
/// - Asynchronous person segmentation throttled to every 5 frames (~6 Hz at 30 fps)
///   on a dedicated background queue to never block the camera capture thread.
/// - Conforms to ExternalVideoProcessingDelegate.
public class FrameProcessor: NSObject, ExternalVideoProcessingDelegate {

    public enum EffectState {
        case blur(radius: Float)
        case color(color: UInt32)
        case image(image: UIImage, fit: String)
    }

    /// Segmentation frequency: run on every available frame (~30 fps on iPhone 15, ~7ms inference) (T4.4).
    public static let segmentEveryNFrames = 1
    public static let minSegmentInterval = 1
    public static let maxSegmentInterval = 10
    public static let fpsMonitorWindowFrames = 45
    public static let degradeFpsThreshold: Double = 14.0
    public static let criticalLowFps: Double = 10.0

    /// FR-21: fps must stay >= this for `recoveryStableWindows` to recover.
    public static let recoverFpsThreshold: Double = 20.0
    public static let recoveryStableWindows = 2

    private let lock = NSLock()
    private var frames: Int = 0
    private var _lastRotation: Int32 = 0
    private var _lastWidth: Int32 = 0
    private var _lastHeight: Int32 = 0
    private var _bufferType: String = ""
    private var isReleased: Bool = false

    public private(set) var segmentationWidth: Int = 256
    public private(set) var edgeSmoothing: Float = 0.5
    public private(set) var targetFps: Int = 30

    // T14.2 (FR-20): temporal mask smoothing at mask upload (ADR 0002 §7).
    // 0 = raw upload, identical to v0.1.
    public private(set) var maskTemporalSmoothing: Float = 0.7
    private let maskSmoother = MaskTemporalSmoother()

    // T14.2/T14.3 measurement hooks: non-nil mode overrides production
    // smoothing from the example's flicker-test page (not public API).
    private var testSmoothingMode: String?
    private var testSmoothingValue: Float = 0
    private var testSmoothingD0: Float = MaskTemporalSmoother.adaptiveD0
    private var testStage = "-"
    private var fpsLogNs: Int64 = 0
    private var fpsLogFrames = 0
    private var fpsLogValue: Double = 0
    public internal(set) var adaptiveSegmentInterval: Int = 1
    public private(set) var isFallbackDisabled: Bool = false

    // T14.4 (FR-21): fallback recovery state (guarded by `lock`).
    /// Whether `BackgroundQuality.autoRecovery` is enabled (opt-in).
    public private(set) var autoRecovery: Bool = false
    /// Last user-configured segmentation width; stage-1 restore target.
    private var configuredWidth: Int = 256
    /// Effect stashed when stage-2 disabled the pipeline; restored on resume.
    private var stashedEffect: EffectState?
    /// One-shot latch: cleared on auto-resume, set again only by a manual
    /// setEffect/setQuality, so a device that cannot keep up stays disabled
    /// instead of flapping (PRD "tanpa osilasi").
    private var autoRecoveryArmed: Bool = true
    /// Consecutive healthy fps windows; drives both recovery paths.
    private var healthyFpsWindowCount: Int = 0
    /// True after auto-resume until the first frame composites (FR-21 status).
    private var awaitingActiveAfterResume: Bool = false

    private var lastCompositedTimestampNs: Int64 = 0

    // Performance window tracking (FR-12)
    private var windowStartTimestampNs: Int64 = 0
    private var windowFrameCount: Int = 0
    private var lowFpsWindowCount: Int = 0
    private var lastFrameTimestampNs: Int64 = 0
    public static let frameGapResetNs: Int64 = 1_000_000_000

    public var currentEffect: EffectState?

    private let compositor: FrameCompositor
    private var segmenter: MaskSegmenter?
    private var segmenterProvider: (() throws -> MaskSegmenter)?
    private let segmentQueue = DispatchQueue(
        label: "com.azmi010.mi_virtual_background_kit.segmentation",
        qos: .userInteractive
    )
    private var isSegmenting: Bool = false

    public var onStatusChange: ((String) -> Void)?
    public var onFallbackEvent: (([String: Any]) -> Void)?

    public var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    public var lastRotation: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return _lastRotation
    }

    public var lastWidth: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return _lastWidth
    }

    public var lastHeight: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return _lastHeight
    }

    public var bufferType: String {
        lock.lock()
        defer { lock.unlock() }
        return _bufferType
    }

    public init(
        compositor: FrameCompositor? = nil,
        segmenterProvider: (() throws -> MaskSegmenter)? = nil,
        onStatusChange: ((String) -> Void)? = nil,
        onFallbackEvent: (([String: Any]) -> Void)? = nil
    ) {
        self.compositor = compositor ?? GpuCompositor()
        self.segmenterProvider = segmenterProvider
        self.onStatusChange = onStatusChange
        self.onFallbackEvent = onFallbackEvent
        super.init()
    }

    public func setBlurEffect(radius: Float) throws {
        let resumed = adoptManualEffect(.blur(radius: radius))
        try ensureSegmenter()
        if resumed { emitRecovered(reason: "manual") }
    }

    public func setColorEffect(color: UInt32) throws {
        let resumed = adoptManualEffect(.color(color: color))
        try ensureSegmenter()
        if resumed { emitRecovered(reason: "manual") }
    }

    public func setImageEffect(image: UIImage, fit: String) throws {
        let resumed = adoptManualEffect(.image(image: image, fit: fit))
        compositor.uploadImage(image)
        try ensureSegmenter()
        if resumed { emitRecovered(reason: "manual") }
    }

    /// Adopts a user-chosen effect: leaves the fallback-disabled state, drops
    /// the stashed effect, and re-arms auto-recovery (manual intervention,
    /// FR-21). Returns true when this re-enabled an effect stage-2 disabled.
    private func adoptManualEffect(_ effect: EffectState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasFallbackDisabled = isFallbackDisabled
        isFallbackDisabled = false
        stashedEffect = nil
        autoRecoveryArmed = true
        awaitingActiveAfterResume = false
        currentEffect = effect
        return wasFallbackDisabled
    }

    public func setQuality(
        segmentationWidth: Int,
        edgeSmoothing: Float,
        targetFps: Int,
        maskTemporalSmoothing: Float = 0.7,
        autoRecovery: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.configuredWidth = segmentationWidth
        self.segmentationWidth = segmentationWidth
        self.edgeSmoothing = max(0.0, min(1.0, edgeSmoothing))
        self.targetFps = max(1, min(60, targetFps))
        self.maskTemporalSmoothing = max(0.0, min(1.0, maskTemporalSmoothing))
        self.autoRecovery = autoRecovery
        // A quality change is a manual intervention: re-arm auto-recovery (FR-21).
        self.autoRecoveryArmed = true
        compositor.edgeSmoothing = self.edgeSmoothing
        maskSmoother.reset()
    }

    /// T14.2/T14.3 measurement hook: overrides mask smoothing
    /// (`mode`: `none`/`ema`/`adaptive`; `d0` nil = default) and resets the
    /// history. Nil mode resumes production smoothing from `setQuality`.
    public func setTestSmoothing(mode: String?, value: Float, d0: Float?) {
        lock.lock()
        testSmoothingMode = mode
        testSmoothingValue = max(0, min(1, value))
        testSmoothingD0 = d0 ?? MaskTemporalSmoother.adaptiveD0
        lock.unlock()
        maskSmoother.reset()
    }

    /// T14.2/T14.3 measurement hook: tags `T133|` lines and resets history.
    public func setTestStage(_ stage: String) {
        lock.lock()
        testStage = stage
        lock.unlock()
        maskSmoother.reset()
    }

    public func clearEffect() {
        lock.lock()
        // User chose no effect: cancel any pending fallback recovery (FR-21).
        isFallbackDisabled = false
        stashedEffect = nil
        awaitingActiveAfterResume = false
        resetEffectStateLocked()
        lock.unlock()
        maskSmoother.reset()
        compositor.clearMask()
    }

    /// Nulls the active effect and resets the performance windows. Leaves the
    /// fallback flags alone: stage-2 stashes the effect and sets
    /// `isFallbackDisabled` first. Caller holds `lock`.
    private func resetEffectStateLocked() {
        currentEffect = nil
        lastCompositedTimestampNs = 0
        windowStartTimestampNs = 0
        windowFrameCount = 0
        lowFpsWindowCount = 0
        healthyFpsWindowCount = 0
        awaitingActiveAfterResume = false
    }

    private func ensureSegmenter() throws {
        lock.lock()
        defer { lock.unlock() }
        if segmenter == nil {
            do {
                if let provider = segmenterProvider {
                    segmenter = try provider()
                } else {
                    segmenter = try Segmenter()
                }
            } catch {
                NSLog("MiVBG failed to initialize Segmenter: \(error)")
                onStatusChange?("error")
                throw error
            }
        }
    }

    public func onFrame(_ frame: RTCVideoFrame) -> RTCVideoFrame {
        lock.lock()
        if isReleased {
            lock.unlock()
            return frame
        }

        frames += 1
        let currentFrames = frames
        _lastRotation = Int32(frame.rotation.rawValue)
        _lastWidth = Int32(frame.width)
        _lastHeight = Int32(frame.height)
        if _bufferType.isEmpty {
            _bufferType = String(describing: type(of: frame.buffer))
            print("[MiVBGProcessor] First frame: \(_bufferType), rot=\(_lastRotation), size=\(_lastWidth)x\(_lastHeight)")
        }

        if currentFrames % 150 == 0 {
            print("[MiVBGProcessor] Frame pass #\(currentFrames) (30 fps stable, \(_lastWidth)x\(_lastHeight))")
        }

        let effect = currentEffect
        let fallbackDisabled = isFallbackDisabled
        let watchingFallback = fallbackDisabled && autoRecovery
        lock.unlock()

        let currentTimestamp = frame.timeStampNs > 0 ? frame.timeStampNs : Int64(Date().timeIntervalSince1970 * 1_000_000_000)

        // FR-12/FR-21: monitor fps while an effect is active, or while a
        // stage-2 fallback watches for auto-recovery.
        if effect != nil || watchingFallback {
            lock.lock()
            // FR-09: background/foreground or camera restart leaves a multi-second
            // gap; a stale window would measure near-zero fps and falsely trip FR-12.
            if lastFrameTimestampNs != 0 && currentTimestamp - lastFrameTimestampNs > FrameProcessor.frameGapResetNs {
                windowStartTimestampNs = 0
                windowFrameCount = 0
                lowFpsWindowCount = 0
                healthyFpsWindowCount = 0
            }
            lastFrameTimestampNs = currentTimestamp

            // FR-12: Monitor frame rate across sliding window and evaluate performance fallback
            var shouldEvaluate = false
            var measuredFps: Double = 0.0
            if windowStartTimestampNs == 0 {
                windowStartTimestampNs = currentTimestamp
                windowFrameCount = 0
            } else {
                windowFrameCount += 1
                if windowFrameCount >= FrameProcessor.fpsMonitorWindowFrames {
                    let elapsedSec = Double(currentTimestamp - windowStartTimestampNs) / 1_000_000_000.0
                    if elapsedSec > 0.0 {
                        measuredFps = Double(windowFrameCount) / elapsedSec
                        shouldEvaluate = true
                    }
                    windowStartTimestampNs = currentTimestamp
                    windowFrameCount = 0
                }
            }
            lock.unlock()

            if shouldEvaluate {
                evaluatePerformance(measuredFps: measuredFps)
            }
        }

        // 1. Bypass when no effect is applied or disabled by fallback (FR-04, FR-12)
        guard let activeEffect = effect, !fallbackDisabled else {
            return frame
        }

        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else {
            return frame
        }
        let pixelBuffer = rtcBuffer.pixelBuffer

        lock.lock()
        let fps = targetFps
        let lastNs = lastCompositedTimestampNs
        let interval = adaptiveSegmentInterval
        lock.unlock()

        if fps < 30 && lastNs > 0 {
            let elapsed = currentTimestamp - lastNs
            let minIntervalNs = Int64(1_000_000_000 / fps)
            if elapsed < (minIntervalNs * 85 / 100) {
                if let reused = compositor.reuseLastFrame(frame: frame) {
                    return reused
                }
            }
        }

        // 2. Trigger asynchronous segmentation adaptively if worker is idle
        if !compositor.hasMask || currentFrames % interval == 0 {
            triggerSegmentation(pixelBuffer: pixelBuffer, rotation: frame.rotation)
        }

        // 3. Composite using latest available mask
        if compositor.hasMask {
            let composed: RTCVideoFrame?
            switch activeEffect {
            case .blur(let radius):
                composed = compositor.composeBlur(frame: frame, radius: radius)
            case .color(let color):
                composed = compositor.composeColor(frame: frame, color: color)
            case .image(_, let fit):
                composed = compositor.composeImage(frame: frame, fit: fit)
            }
            if let output = composed {
                lock.lock()
                lastCompositedTimestampNs = currentTimestamp
                let fireActive = awaitingActiveAfterResume
                awaitingActiveAfterResume = false
                lock.unlock()
                if fireActive {
                    onStatusChange?("active")
                }
                return output
            }
        }

        return frame
    }

    private func triggerSegmentation(pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation) {
        lock.lock()
        guard !isReleased, !isSegmenting, let seg = segmenter else {
            lock.unlock()
            return
        }
        isSegmenting = true
        lock.unlock()

        segmentQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if self.isReleased {
                self.isSegmenting = false
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            defer {
                self.lock.lock()
                self.isSegmenting = false
                self.lock.unlock()
            }

            do {
                let startNs = DispatchTime.now().uptimeNanoseconds
                let mask = try seg.segment(pixelBuffer: pixelBuffer, rotation: rotation)
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - startNs
                let inferenceMs = Double(elapsedNs) / 1_000_000.0

                self.lock.lock()
                let released = self.isReleased
                if inferenceMs < 15.0 {
                    self.adaptiveSegmentInterval = 1
                } else if inferenceMs < 30.0 {
                    self.adaptiveSegmentInterval = 2
                } else if inferenceMs <= 50.0 {
                    self.adaptiveSegmentInterval = 3
                } else if inferenceMs <= 85.0 {
                    self.adaptiveSegmentInterval = 5
                } else if inferenceMs <= 150.0 {
                    self.adaptiveSegmentInterval = 8
                } else {
                    self.adaptiveSegmentInterval = 10
                }
                self.lock.unlock()

                if !released {
                    self.applyMask(mask, rotation: Int32(rotation.rawValue))
                }
            } catch {
                NSLog("MiVBG segmentation error: \(error)")
            }
        }
    }

    /// T14.2: uploads the mask, temporal-smoothing it first (ADR 0002 §7), and
    /// emits one `T133|` metric line per mask while smoothing is active.
    /// `maskTemporalSmoothing == 0` uploads the raw mask (identical to v0.1).
    private func applyMask(_ mask: PersonMask, rotation: Int32) {
        lock.lock()
        let hookMode = testSmoothingMode
        let value = hookMode != nil ? testSmoothingValue : maskTemporalSmoothing
        let d0 = hookMode != nil ? testSmoothingD0 : MaskTemporalSmoother.adaptiveD0
        lock.unlock()
        guard !(hookMode == nil && value <= 0) else {
            maskSmoother.reset()
            compositor.uploadMask(mask, rotation: rotation)
            return
        }
        let mode = hookMode ?? "adaptive"
        let res = maskSmoother.process(raw: mask.alpha, mode: mode, value: value, d0: d0)
        logMaskMetrics(res, mode: mode, value: value, d0: d0)
        compositor.uploadMask(
            PersonMask(
                alpha: res.alpha,
                width: mask.width,
                height: mask.height,
                rotation: mask.rotation
            ),
            rotation: rotation
        )
    }

    /// One metric line per smoothed mask; parsed by tool/smoothing_metrics.py.
    private func logMaskMetrics(
        _ res: MaskTemporalSmoother.Result,
        mode: String,
        value: Float,
        d0: Float
    ) {
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        lock.lock()
        if fpsLogNs == 0 {
            fpsLogNs = now
            fpsLogFrames = frames
        } else if now - fpsLogNs >= 1_000_000_000 {
            fpsLogValue = Double(frames - fpsLogFrames) * 1_000_000_000.0 / Double(now - fpsLogNs)
            fpsLogNs = now
            fpsLogFrames = frames
        }
        let fps = fpsLogValue
        let stage = testStage
        lock.unlock()
        print(String(
            format: "T133| m=%@ v=%.2f d0=%.2f st=%@ rev=%d chg=%d d=%.1f lag=%.1f px=%d us=%llu fps=%.1f",
            mode, value, d0, stage, res.rev, res.chg, res.dPct, res.lagPct, res.alpha.count, res.us, fps
        ))
    }

    public func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        currentEffect = nil
        stashedEffect = nil
        awaitingActiveAfterResume = false
        lock.unlock()

        segmentQueue.sync {}

        lock.lock()
        defer { lock.unlock() }
        compositor.release()
        segmenter?.close()
        segmenter = nil
    }

    internal func evaluatePerformance(measuredFps: Double) {
        lock.lock()
        if isReleased {
            lock.unlock()
            return
        }

        // FR-21: while bypassed by stage-2, watch for stable fps to auto-resume.
        if isFallbackDisabled {
            if autoRecovery, autoRecoveryArmed,
               measuredFps >= FrameProcessor.recoverFpsThreshold {
                healthyFpsWindowCount += 1
                if healthyFpsWindowCount >= FrameProcessor.recoveryStableWindows {
                    // One shot: if the device fails again it stays disabled
                    // until a manual setEffect/setQuality re-arms (no flapping).
                    autoRecoveryArmed = false
                    lock.unlock()
                    resumeFromFallback(reason: "auto")
                    return
                }
                lock.unlock()
                return
            }
            healthyFpsWindowCount = 0
            lock.unlock()
            return
        }

        // User chose no effect: nothing to monitor (FR-04).
        guard currentEffect != nil else {
            lock.unlock()
            return
        }

        if measuredFps < FrameProcessor.degradeFpsThreshold {
            healthyFpsWindowCount = 0
            lowFpsWindowCount += 1
            if segmentationWidth > 192 {
                let oldWidth = segmentationWidth
                segmentationWidth = 192
                adaptiveSegmentInterval = min(FrameProcessor.maxSegmentInterval, adaptiveSegmentInterval + 2)
                let fps = targetFps
                lock.unlock()

                NSLog("[MiVBG] Performance drop detected: fps=%.1f < %.1f. Degraded resolution %d -> 192", measuredFps, FrameProcessor.degradeFpsThreshold, oldWidth)
                let event: [String: Any] = [
                    "event": "fallback",
                    "action": "qualityDegraded",
                    "reason": String(format: "fps_drop_%.1f", measuredFps),
                    "segmentationWidth": 192,
                    "targetFps": fps
                ]
                onFallbackEvent?(event)
            } else if measuredFps < FrameProcessor.criticalLowFps && lowFpsWindowCount >= 2 {
                // Stage 2: stash the effect before clearing so FR-21 can restore it.
                stashedEffect = currentEffect
                isFallbackDisabled = true
                resetEffectStateLocked()
                lock.unlock()
                maskSmoother.reset()
                compositor.clearMask()

                NSLog("[MiVBG] Critical performance drop: fps=%.1f < %.1f. Auto-disabled effect.", measuredFps, FrameProcessor.criticalLowFps)
                onStatusChange?("idle")
                let event: [String: Any] = [
                    "event": "fallback",
                    "action": "disabled",
                    "reason": String(format: "fps_critical_%.1f", measuredFps)
                ]
                onFallbackEvent?(event)
            } else {
                lock.unlock()
            }
        } else {
            lowFpsWindowCount = 0
            // FR-21 hysteresis: restore the configured quality only after fps
            // stays >= recoverFpsThreshold (dead band between 14 and 20).
            if autoRecovery, measuredFps >= FrameProcessor.recoverFpsThreshold {
                healthyFpsWindowCount += 1
                if healthyFpsWindowCount >= FrameProcessor.recoveryStableWindows,
                   segmentationWidth != configuredWidth {
                    let restored = configuredWidth
                    segmentationWidth = restored
                    healthyFpsWindowCount = 0
                    lock.unlock()
                    NSLog("[MiVBG] T144| quality restored width=%d fps=%.1f", restored, measuredFps)
                    emitRecovered(reason: "auto_quality")
                    return
                }
            } else {
                healthyFpsWindowCount = 0
            }
            lock.unlock()
        }
    }

    /// Restores the effect stashed by stage-2 (FR-21). Emits `recovered`,
    /// then status `initializing`; the first composited frame emits `active`
    /// (PRD: disabled -> initializing -> active).
    private func resumeFromFallback(reason: String) {
        lock.lock()
        let stash = stashedEffect
        isFallbackDisabled = false
        stashedEffect = nil
        healthyFpsWindowCount = 0
        lowFpsWindowCount = 0
        windowStartTimestampNs = 0
        windowFrameCount = 0
        if segmentationWidth != configuredWidth {
            segmentationWidth = configuredWidth
        }
        // Non-nil: stage-2 only disables while an effect is active.
        currentEffect = stash
        awaitingActiveAfterResume = true
        lock.unlock()

        NSLog("[MiVBG] T144| recovered reason=%@", reason)
        emitRecovered(reason: reason)
        onStatusChange?("initializing")
    }

    private func emitRecovered(reason: String) {
        lock.lock()
        let width = segmentationWidth
        let fps = targetFps
        lock.unlock()
        let event: [String: Any] = [
            "event": "fallback",
            "action": "recovered",
            "reason": reason,
            "segmentationWidth": width,
            "targetFps": fps
        ]
        onFallbackEvent?(event)
    }

    public func simulatePerformanceDrop(_ measuredFps: Double) {
        evaluatePerformance(measuredFps: measuredFps)
    }
}
