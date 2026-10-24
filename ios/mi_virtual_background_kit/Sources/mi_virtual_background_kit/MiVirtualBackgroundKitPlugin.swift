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
public class MiVirtualBackgroundKitPlugin: NSObject, FlutterPlugin {
  private var spikeProcessor: SpikeFrameProcessor?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "mi_virtual_background_kit", binaryMessenger: registrar.messenger())
    let instance = MiVirtualBackgroundKitPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "spikeAttach":
      guard let args = call.arguments as? [String: Any],
            let trackId = args["trackId"] as? String else {
        result(FlutterError(code: "bad_args", message: "trackId is required", details: nil))
        return
      }
      let processor = SpikeFrameProcessor()
      let attached = SpikeHook.attach(trackId: trackId, processor: processor)
      if attached {
        spikeProcessor = processor
      }
      result(attached)
    case "spikeFrameCount":
      result(spikeProcessor?.frameCount ?? 0)
    case "spikeReport":
      let p = spikeProcessor
      NSLog(
        "MiVBGSpike report frames=\(p?.frameCount ?? 0) "
          + "buffer=\(p?.bufferType ?? "") rot=\(p?.rotation ?? 0) "
          + "size=\(p?.width ?? 0)x\(p?.height ?? 0)")
      result([
        "frames": p?.frameCount ?? 0,
        "bufferType": p?.bufferType ?? "",
        "rotation": p?.rotation ?? 0,
        "width": p?.width ?? 0,
        "height": p?.height ?? 0,
      ])
    case "spikeInfo":
      let p = spikeProcessor
      result([
        "frames": p?.frameCount ?? 0,
        "bufferType": p?.bufferType ?? "",
        "rotation": p?.rotation ?? 0,
        "width": p?.width ?? 0,
        "height": p?.height ?? 0,
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
      // CPU readback benchmark is Android-only; no-op so the example timer
      // does not hit MissingPluginException.
      result(true)
    case "spikeDetach":
      guard let args = call.arguments as? [String: Any],
            let trackId = args["trackId"] as? String else {
        result(false)
        return
      }
      let ok = SpikeHook.detach(trackId: trackId, processor: spikeProcessor)
      spikeProcessor = nil
      result(ok)
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
