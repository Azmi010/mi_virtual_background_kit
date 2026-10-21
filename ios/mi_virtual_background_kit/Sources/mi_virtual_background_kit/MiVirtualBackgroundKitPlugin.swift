import Flutter
import UIKit
import WebRTC
import flutter_webrtc

/// Spike T0.5: prove that a frame processor can be installed on a local camera
/// track created by flutter_webrtc and that transformed frames reach the
/// renderer.
///
/// The transform inverts the chroma planes of an I420 frame, which produces a
/// visible colour shift in the preview.
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

/// Frame processor that inverts the chroma planes of an I420 frame.
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
/// The camera buffer on iOS is a read-only `RTCCVPixelBuffer` (CVPixelBuffer),
/// so the spike swaps it for a copy that has its chroma inverted. The real
/// implementation will composite on the GPU with Core Image or Metal.
enum SpikeInvert {
  static func apply(_ frame: RTCVideoFrame) -> RTCVideoFrame {
    guard let pixelBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
      return frame
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!

    // BGRA: swap the red and blue channels, which is visible in the preview.
    for y in 0..<height {
      let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      for x in stride(from: 0, to: width, by: 2) {
        let i = x * 4
        let r = row[i]
        row[i] = row[i + 2]
        row[i + 2] = r
      }
    }
    return frame
  }
}
