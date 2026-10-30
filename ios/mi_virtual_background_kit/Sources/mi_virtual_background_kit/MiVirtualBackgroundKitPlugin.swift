import Flutter
import UIKit
import WebRTC
import flutter_webrtc

/// Spike T0.5: prove that a frame processor can be installed on a local camera
/// track created by flutter_webrtc and that transformed frames reach the
/// renderer.
///
/// The transform swaps chroma data in the camera's pixel buffer (Cb/Cr for
/// YCbCr, R/B for BGRA), which produces a visible colour shift in the preview.
public class MiVirtualBackgroundKitPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var spikeProcessor: SpikeFrameProcessor?
  private var frameProcessor: FrameProcessor?
  private var attachedTrack: LocalVideoTrack?
  private var eventSink: FlutterEventSink?
  private var currentStatus: String = "idle"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "mi_virtual_background_kit", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(name: "mi_virtual_background_kit/status", binaryMessenger: registrar.messenger())
    let instance = MiVirtualBackgroundKitPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    eventChannel.setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    events(currentStatus)
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  private func updateStatus(_ status: String) {
    self.currentStatus = status
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(status)
    }
  }

  /// Attaches [processor] to [LocalVideoTrack] via flutter_webrtc plugin singleton.
  /// Caches the track reference directly per ADR 0001 §1.
  private func attachFrameProcessor(trackId: String, processor: ExternalVideoProcessingDelegate) -> LocalVideoTrack? {
    guard let plugin = FlutterWebRTCPlugin.sharedSingleton(),
          let track = plugin.localTracks?[trackId] as? LocalVideoTrack else {
      NSLog("MiVBG attach failed: track \(trackId) not found in localTracks")
      return nil
    }
    track.addProcessing(processor)
    return track
  }

  /// Detaches [processor] from [track]; idempotent per FR-06.
  private func detachFrameProcessor(track: LocalVideoTrack?, processor: ExternalVideoProcessingDelegate?) {
    guard let track = track else { return }
    if let processor = processor {
      track.removeProcessing(processor)
    }
  }

  /// Releases the production FrameProcessor and detaches from the cached track; idempotent.
  private func releaseFrameProcessor() {
    if let track = attachedTrack, let processor = frameProcessor {
      detachFrameProcessor(track: track, processor: processor)
      processor.release()
    }
    if let track = attachedTrack, let spike = spikeProcessor {
      detachFrameProcessor(track: track, processor: spike)
    }
    attachedTrack = nil
    frameProcessor = nil
    spikeProcessor = nil
  }

  private func runSegmenterSelfTest() {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        print("[MiVBGSegmenter] Starting MediaPipe Segmenter test on physical device...")
        let segmenter = try Segmenter()
        defer { segmenter.close() }
        let size = CGSize(width: 256, height: 256)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        UIColor.darkGray.setFill()
        UIBezierPath(ovalIn: CGRect(x: 64, y: 32, width: 128, height: 160)).fill()
        let testImage = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()

        let start = CFAbsoluteTimeGetCurrent()
        let mask = try segmenter.segment(image: testImage)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let logMsg = "MiVBGSegmenter SUCCESS: mask \(mask.width)x\(mask.height) person=\(mask.personPixelCount) time=\(elapsedMs)ms"
        print("[MiVBGSegmenter] \(logMsg)")
        NSLog(logMsg)
      } catch {
        let err = "MiVBGSegmenter ERROR: \(error)"
        print("[MiVBGSegmenter] \(err)")
        NSLog(err)
      }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "isSupported":
      runSegmenterSelfTest()
      if #available(iOS 15.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "attach":
      guard let args = call.arguments as? [String: Any],
            let trackId = args["trackId"] as? String,
            !trackId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        updateStatus("error")
        result(FlutterError(code: "invalidTrack", message: "trackId is required", details: nil))
        return
      }

      updateStatus("initializing")
      // Re-attach replaces: never stack processors on one track (ADR 0001 §1).
      releaseFrameProcessor()

      let processor = FrameProcessor { [weak self] status in
        self?.updateStatus(status)
      }

      guard let track = attachFrameProcessor(trackId: trackId, processor: processor) else {
        updateStatus("error")
        result(FlutterError(code: "invalidTrack", message: "no local video track: \(trackId)", details: nil))
        return
      }

      self.attachedTrack = track
      self.frameProcessor = processor
      updateStatus("active")
      print("[MiVBG] Successfully attached production FrameProcessor to track: \(trackId)")
      result(nil)

    case "detach":
      let wasAttached = (frameProcessor != nil)
      releaseFrameProcessor()
      updateStatus("idle")
      print("[MiVBG] Detached processor (wasAttached=\(wasAttached))")
      result(nil)

    case "dispose":
      releaseFrameProcessor()
      updateStatus("idle")
      print("[MiVBG] Disposed plugin resources")
      result(nil)

    case "spikeAttach":
      runSegmenterSelfTest()
      guard let args = call.arguments as? [String: Any],
            let trackId = args["trackId"] as? String else {
        result(FlutterError(code: "bad_args", message: "trackId is required", details: nil))
        return
      }
      releaseFrameProcessor()
      let processor = FrameProcessor { [weak self] status in
        self?.updateStatus(status)
      }
      guard let track = attachFrameProcessor(trackId: trackId, processor: processor) else {
        result(false)
        return
      }
      self.attachedTrack = track
      self.frameProcessor = processor
      updateStatus("active")
      print("[MiVBG] spikeAttach: attached FrameProcessor to \(trackId)")
      result(true)
    case "spikeFrameCount":
      result(frameProcessor?.frameCount ?? spikeProcessor?.frameCount ?? 0)
    case "spikeReport", "spikeInfo":
      let p = frameProcessor
      let sp = spikeProcessor
      let count = p?.frameCount ?? sp?.frameCount ?? 0
      let buf = p?.bufferType ?? sp?.bufferType ?? ""
      let rot = p?.lastRotation ?? sp?.rotation ?? 0
      let w = p?.lastWidth ?? sp?.width ?? 0
      let h = p?.lastHeight ?? sp?.height ?? 0
      result([
        "frames": count,
        "bufferType": buf,
        "rotation": rot,
        "width": w,
        "height": h,
      ])
    case "spikeGpuInfo":
      result([:])
    case "spikeEnableGpu":
      result(false)
    case "spikeSetEnabled":
      let args = call.arguments as? [String: Any]
      spikeProcessor?.enabled = (args?["enabled"] as? Bool) ?? true
      result(true)
    case "spikeBenchmarkReadback":
      runSegmenterSelfTest()
      result(true)
    case "spikeDetach":
      releaseFrameProcessor()
      updateStatus("idle")
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Frame processor that swaps chroma data so the preview visibly changes.
final class SpikeFrameProcessor: NSObject, ExternalVideoProcessingDelegate {
  private let lock = NSLock()
  private var frames = 0
  private var firstBufferType: String?
  private var firstRotation: Int32 = 0
  private var firstWidth: Int32 = 0
  private var firstHeight: Int32 = 0

  var enabled = true

  var frameCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return frames
  }

  var bufferType: String? {
    lock.lock()
    defer { lock.unlock() }
    return firstBufferType
  }

  var rotation: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return firstRotation
  }

  var width: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return firstWidth
  }

  var height: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return firstHeight
  }

  func onFrame(_ frame: RTCVideoFrame) -> RTCVideoFrame {
    lock.lock()
    frames += 1
    if firstBufferType == nil {
      firstBufferType = String(describing: type(of: frame.buffer))
      firstRotation = Int32(frame.rotation.rawValue)
      firstWidth = Int32(frame.width)
      firstHeight = Int32(frame.height)
      NSLog(
        "MiVBGSpike first frame buffer=\(firstBufferType!) rot=\(firstRotation) "
          + "size=\(firstWidth)x\(firstHeight)")
    }
    if frames % 60 == 0 {
      NSLog("MiVBGSpike frames=\(frames)")
    }
    if frames == 30 {
      NSLog("MiVBGSpike MARK frames=30")
    }
    if frames % 30 == 0 {
      // Write a marker file so the host can verify the hook is live even when
      // the device console is not attached.
      let path = NSTemporaryDirectory() + "mivbg-spike.txt"
      let text = "frames=\(frames) buffer=\(firstBufferType ?? "") rot=\(firstRotation) "
        + "size=\(firstWidth)x\(firstHeight)"
      try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    let shouldTransform = enabled
    lock.unlock()

    guard shouldTransform else { return frame }
    return SpikeInvert.apply(frame)
  }
}

/// Installs the processor on the flutter_webrtc local track.
enum SpikeHook {
  static func attach(trackId: String, processor: SpikeFrameProcessor) -> Bool {
    guard let plugin = FlutterWebRTCPlugin.sharedSingleton(),
          let track = plugin.localTracks?[trackId] as? LocalVideoTrack else {
      NSLog("MiVBGSpike attach failed: track \(trackId) not found")
      return false
    }
    track.addProcessing(processor)
    return true
  }

  static func detach(trackId: String, processor: SpikeFrameProcessor?) -> Bool {
    guard let plugin = FlutterWebRTCPlugin.sharedSingleton(),
          let track = plugin.localTracks?[trackId] as? LocalVideoTrack else {
      return false
    }
    if let processor {
      track.removeProcessing(processor)
    }
    return true
  }
}

/// Marks the frame buffer so the preview visibly changes.
///
/// The pixel format is detected at runtime: camera frames may arrive as
/// `32BGRA` or as a biplanar YCbCr buffer. For YCbCr the Cb/Cr plane pairs are
/// swapped (the iOS equivalent of the Android spike's U/V swap); the luma plane
/// is left untouched so the image stays free of banding.
///
/// The real implementation will composite on the GPU with Core Image or Metal.
enum SpikeInvert {
  private static var loggedFormat = false
  private static var loggedLockFailure = false
  private static var loggedUnsupported = false

  static func apply(_ frame: RTCVideoFrame) -> RTCVideoFrame {
    guard let pixelBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
      return frame
    }

    let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
    if !loggedFormat {
      loggedFormat = true
      NSLog(
        "MiVBGSpike pixelFormat=\(fourCC(fmt)) planes=\(CVPixelBufferGetPlaneCount(pixelBuffer))")
    }

    let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard status == kCVReturnSuccess else {
      if !loggedLockFailure {
        loggedLockFailure = true
        NSLog("MiVBGSpike CVPixelBufferLockBaseAddress failed: \(status)")
      }
      return frame
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    switch fmt {
    case kCVPixelFormatType_32BGRA:
      swapBGRA(pixelBuffer)
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      swapChromaPlane(pixelBuffer)
    default:
      if !loggedUnsupported {
        loggedUnsupported = true
        NSLog("MiVBGSpike unsupported pixel format \(fourCC(fmt)); no transform applied")
      }
    }
    return frame
  }

  /// Swaps the red and blue channels of every BGRA pixel, visible as a hue shift.
  private static func swapBGRA(_ pixelBuffer: CVPixelBuffer) {
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
      let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      for x in 0..<width {
        let i = x * 4
        if i + 2 >= bytesPerRow { break }
        let r = row[i + 2]
        row[i + 2] = row[i]
        row[i] = r
      }
    }
  }

  /// Swaps each Cb/Cr byte pair in plane 1 of a biplanar YCbCr buffer.
  ///
  /// Chroma is interleaved (CbCrCbCr...) so this is a straight pairwise swap
  /// across the row; luma (plane 0) is not modified.
  private static func swapChromaPlane(_ pixelBuffer: CVPixelBuffer) {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) > 1,
          let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else { return }
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    for y in 0..<height {
      let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      var x = 0
      while x + 1 < bytesPerRow {
        let t = row[x]
        row[x] = row[x + 1]
        row[x + 1] = t
        x += 2
      }
    }
  }

  private static func fourCC(_ value: OSType) -> String {
    let bytes: [UInt8] = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
    let s = String(bytes: bytes, encoding: .ascii) ?? "?"
    return "\(s) (0x\(String(value, radix: 16)))"
  }
}
