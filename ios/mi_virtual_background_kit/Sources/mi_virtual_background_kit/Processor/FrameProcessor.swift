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
        lock.lock()
        isFallbackDisabled = false
        currentEffect = .blur(radius: radius)
        lock.unlock()
        try ensureSegmenter()
    }

    public func setColorEffect(color: UInt32) throws {
        lock.lock()
        isFallbackDisabled = false
        currentEffect = .color(color: color)
        lock.unlock()
        try ensureSegmenter()
    }

    public func setImageEffect(image: UIImage, fit: String) throws {
        lock.lock()
        isFallbackDisabled = false
        currentEffect = .image(image: image, fit: fit)
        lock.unlock()
        compositor.uploadImage(image)
        try ensureSegmenter()
    }

    public func setQuality(
        segmentationWidth: Int,
        edgeSmoothing: Float,
        targetFps: Int,
        maskTemporalSmoothing: Float = 0.7
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.segmentationWidth = segmentationWidth
        self.edgeSmoothing = max(0.0, min(1.0, edgeSmoothing))
        self.targetFps = max(1, min(60, targetFps))
        self.maskTemporalSmoothing = max(0.0, min(1.0, maskTemporalSmoothing))
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
        currentEffect = nil
        lastCompositedTimestampNs = 0
        windowStartTimestampNs = 0
        windowFrameCount = 0
        lowFpsWindowCount = 0
        lock.unlock()
        maskSmoother.reset()
        compositor.clearMask()
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
        lock.unlock()

        // 1. Bypass when no effect is applied or disabled by fallback (FR-04, FR-12)
        guard let activeEffect = effect, !fallbackDisabled else {
            return frame
        }

        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else {
            return frame
        }
        let pixelBuffer = rtcBuffer.pixelBuffer

        let currentTimestamp = frame.timeStampNs > 0 ? frame.timeStampNs : Int64(Date().timeIntervalSince1970 * 1_000_000_000)

        // FR-09: background/foreground or camera restart leaves a multi-second
        // gap; a stale window would measure near-zero fps and falsely trip FR-12.
        lock.lock()
        if lastFrameTimestampNs != 0 && currentTimestamp - lastFrameTimestampNs > FrameProcessor.frameGapResetNs {
            windowStartTimestampNs = 0
            windowFrameCount = 0
            lowFpsWindowCount = 0
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
        let fps = targetFps
        let lastNs = lastCompositedTimestampNs
        let interval = adaptiveSegmentInterval
        lock.unlock()

        if shouldEvaluate {
            evaluatePerformance(measuredFps: measuredFps)
        }

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
                lock.unlock()
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
        if currentEffect == nil || isReleased {
            lock.unlock()
            return
        }

        if measuredFps < FrameProcessor.degradeFpsThreshold {
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
                isFallbackDisabled = true
                lock.unlock()
                clearEffect()
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
            lock.unlock()
        }
    }

    public func simulatePerformanceDrop(_ measuredFps: Double) {
        evaluatePerformance(measuredFps: measuredFps)
    }
}
