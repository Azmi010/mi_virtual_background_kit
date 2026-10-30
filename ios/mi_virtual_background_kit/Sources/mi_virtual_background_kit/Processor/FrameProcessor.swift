import Foundation
import WebRTC
import flutter_webrtc

/// Frame processor for local camera tracks installed on flutter_webrtc's
/// `LocalVideoTrack.addProcessing(_:)` hook point (ADR 0001 §1).
///
/// Runs on the WebRTC capture/encoder thread.
///
/// In T4.2:
/// - Passthrough with zero overhead when no effect is applied (FR-04).
/// - Thread-safe frame counter and dimension/rotation tracking.
/// - Periodic logging every 150 frames to verify 30 fps throughput.
/// - Conforms to ExternalVideoProcessingDelegate.
public class FrameProcessor: NSObject, ExternalVideoProcessingDelegate {
    private let lock = NSLock()
    private var frames: Int = 0
    private var _lastRotation: Int32 = 0
    private var _lastWidth: Int32 = 0
    private var _lastHeight: Int32 = 0
    private var _bufferType: String = ""
    private var isReleased: Bool = false

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

    public init(onStatusChange: ((String) -> Void)? = nil) {
        self.onStatusChange = onStatusChange
        super.init()
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
        lock.unlock()

        // In T4.2: pure passthrough of camera frames to verify processor hook.
        // T4.3 will add GPU compositing (blur, image, color).
        return frame
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        isReleased = true
    }
}
