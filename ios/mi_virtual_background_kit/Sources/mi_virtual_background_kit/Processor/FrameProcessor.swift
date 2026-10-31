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
    private var lastCompositedTimestampNs: Int64 = 0

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
        onStatusChange: ((String) -> Void)? = nil
    ) {
        self.compositor = compositor ?? GpuCompositor()
        self.segmenterProvider = segmenterProvider
        self.onStatusChange = onStatusChange
        super.init()
    }

    public func setBlurEffect(radius: Float) throws {
        lock.lock()
        currentEffect = .blur(radius: radius)
        lock.unlock()
        try ensureSegmenter()
    }

    public func setColorEffect(color: UInt32) throws {
        lock.lock()
        currentEffect = .color(color: color)
        lock.unlock()
        try ensureSegmenter()
    }

    public func setImageEffect(image: UIImage, fit: String) throws {
        lock.lock()
        currentEffect = .image(image: image, fit: fit)
        lock.unlock()
        compositor.uploadImage(image)
        try ensureSegmenter()
    }

    public func setQuality(segmentationWidth: Int, edgeSmoothing: Float, targetFps: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.segmentationWidth = segmentationWidth
        self.edgeSmoothing = max(0.0, min(1.0, edgeSmoothing))
        self.targetFps = max(1, min(60, targetFps))
        compositor.edgeSmoothing = self.edgeSmoothing
    }

    public func clearEffect() {
        lock.lock()
        currentEffect = nil
        lastCompositedTimestampNs = 0
        lock.unlock()
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
        lock.unlock()

        // 1. Bypass when no effect is applied (FR-04)
        guard let activeEffect = effect else {
            return frame
        }

        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else {
            return frame
        }
        let pixelBuffer = rtcBuffer.pixelBuffer

        let currentTimestamp = frame.timeStampNs > 0 ? frame.timeStampNs : Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        lock.lock()
        let fps = targetFps
        let lastNs = lastCompositedTimestampNs
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

        // 2. Trigger asynchronous segmentation if worker is idle
        if !compositor.hasMask || currentFrames % FrameProcessor.segmentEveryNFrames == 0 {
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
                let mask = try seg.segment(pixelBuffer: pixelBuffer, rotation: rotation)
                self.lock.lock()
                let released = self.isReleased
                self.lock.unlock()
                if !released {
                    self.compositor.uploadMask(mask, rotation: Int32(rotation.rawValue))
                }
            } catch {
                NSLog("MiVBG segmentation error: \(error)")
            }
        }
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
}
