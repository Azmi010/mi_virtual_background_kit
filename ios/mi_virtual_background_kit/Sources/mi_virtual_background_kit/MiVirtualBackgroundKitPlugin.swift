import Flutter
import UIKit
import Metal
import WebRTC
import flutter_webrtc

/// Method-channel plugin for MiVirtualBackgroundKit on iOS.
public class MiVirtualBackgroundKitPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var frameProcessor: FrameProcessor?
  private var attachedTrack: Any?
  private var eventSink: FlutterEventSink?
  internal var currentStatus: String = "idle"
  private weak var registrar: FlutterPluginRegistrar?

  internal var trackAttacher: ((String, ExternalVideoProcessingDelegate) -> Any?)?
  internal var trackDetacher: ((Any?, ExternalVideoProcessingDelegate?) -> Void)?
  internal var imageDecoder: ((String, Any?) -> UIImage?)?
  internal var frameProcessorFactory: (() -> FrameProcessor)?
  internal var isSupportedChecker: (() -> Bool)?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "mi_virtual_background_kit", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(name: "mi_virtual_background_kit/status", binaryMessenger: registrar.messenger())
    let instance = MiVirtualBackgroundKitPlugin()
    instance.registrar = registrar
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

  internal func updateStatus(_ status: String) {
    self.currentStatus = status
    if Thread.isMainThread {
      self.eventSink?(status)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(status)
      }
    }
  }

  internal func sendFallbackEvent(_ event: [String: Any]) {
    if Thread.isMainThread {
      self.eventSink?(event)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(event)
      }
    }
  }

  /// Attaches [processor] to [LocalVideoTrack] via flutter_webrtc plugin singleton.
  /// Caches the track reference directly per ADR 0001 §1.
  private func attachFrameProcessor(trackId: String, processor: ExternalVideoProcessingDelegate) -> Any? {
    if let customAttacher = trackAttacher {
      return customAttacher(trackId, processor)
    }
    guard let plugin = FlutterWebRTCPlugin.sharedSingleton(),
          let track = plugin.localTracks?[trackId] as? LocalVideoTrack else {
      NSLog("MiVBG attach failed: track \(trackId) not found in localTracks")
      return nil
    }
    track.addProcessing(processor)
    return track
  }

  /// Detaches [processor] from [track]; idempotent per FR-06.
  private func detachFrameProcessor(track: Any?, processor: ExternalVideoProcessingDelegate?) {
    if let customDetacher = trackDetacher {
      customDetacher(track, processor)
      return
    }
    guard let track = track as? LocalVideoTrack else { return }
    if let processor = processor {
      track.removeProcessing(processor)
    }
  }

  /// Releases the production FrameProcessor and detaches from the cached track; idempotent.
  private func releaseFrameProcessor() {
    if let track = attachedTrack {
      if let processor = frameProcessor {
        detachFrameProcessor(track: track, processor: processor)
      }
    }
    frameProcessor?.release()
    attachedTrack = nil
    frameProcessor = nil
  }

  deinit {
    releaseFrameProcessor()
  }

  private func decodeImage(sourceType: String, data: Any?) -> UIImage? {
    if let customDecoder = imageDecoder {
      return customDecoder(sourceType, data)
    }
    guard let data = data else { return nil }
    switch sourceType {
    case "asset":
      guard let assetPath = data as? String else { return nil }
      let key: String
      if let regKey = registrar?.lookupKey(forAsset: assetPath) {
        key = regKey
      } else {
        key = "flutter_assets/" + assetPath
      }
      if let path = Bundle.main.path(forResource: key, ofType: nil) {
        return UIImage(contentsOfFile: path)
      }
      return UIImage(named: assetPath)

    case "file":
      guard let path = data as? String else { return nil }
      return UIImage(contentsOfFile: path)

    case "bytes":
      if let typedData = data as? FlutterStandardTypedData {
        return UIImage(data: typedData.data)
      } else if let rawData = data as? Data {
        return UIImage(data: rawData)
      }
      return nil

    default:
      return nil
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "isSupported":
      if let checker = isSupportedChecker {
        result(checker())
        return
      }
      if #available(iOS 15.0, *) {
        let modelOk = (Segmenter.resolveModelPath() != nil)
        let metalOk = (MTLCreateSystemDefaultDevice() != nil)
        result(modelOk && metalOk)
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

      let processor = frameProcessorFactory?() ?? FrameProcessor()
      processor.onStatusChange = { [weak self] status in
        self?.updateStatus(status)
      }
      processor.onFallbackEvent = { [weak self] event in
        self?.sendFallbackEvent(event)
      }

      if let qualityMap = args["quality"] as? [String: Any] {
        let segW = (qualityMap["segmentationWidth"] as? NSNumber)?.intValue ?? 256
        let edgeSm = (qualityMap["edgeSmoothing"] as? NSNumber)?.floatValue ?? 0.5
        let fps = (qualityMap["targetFps"] as? NSNumber)?.intValue ?? 30
        processor.setQuality(segmentationWidth: segW, edgeSmoothing: edgeSm, targetFps: fps)
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

    case "setEffect":
      guard let args = call.arguments as? [String: Any],
            let type = args["type"] as? String else {
        result(FlutterError(code: "bad_args", message: "type is required", details: nil))
        return
      }

      switch type {
      case "blur":
        let radius = (args["radius"] as? NSNumber)?.floatValue ?? 12.0
        do {
          try frameProcessor?.setBlurEffect(radius: radius)
          updateStatus("active")
          result(nil)
        } catch {
          updateStatus("error")
          result(FlutterError(code: "modelLoadFailed", message: error.localizedDescription, details: nil))
        }

      case "color":
        let colorNum = (args["color"] as? NSNumber)?.uint32Value ?? 0xFF000000
        do {
          try frameProcessor?.setColorEffect(color: colorNum)
          updateStatus("active")
          result(nil)
        } catch {
          updateStatus("error")
          result(FlutterError(code: "modelLoadFailed", message: error.localizedDescription, details: nil))
        }

      case "image":
        let fit = (args["fit"] as? String) ?? "cover"
        let sourceType = (args["sourceType"] as? String) ?? "asset"
        let data = args["data"]

        guard let image = decodeImage(sourceType: sourceType, data: data) else {
          updateStatus("error")
          result(FlutterError(code: "invalidImage", message: "Failed to decode image from \(sourceType)", details: nil))
          return
        }

        do {
          try frameProcessor?.setImageEffect(image: image, fit: fit)
          updateStatus("active")
          result(nil)
        } catch {
          updateStatus("error")
          result(FlutterError(code: "modelLoadFailed", message: error.localizedDescription, details: nil))
        }

      case "none":
        frameProcessor?.clearEffect()
        updateStatus("active")
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }

    case "setQuality":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      let segW = (args["segmentationWidth"] as? NSNumber)?.intValue ?? 256
      let edgeSm = (args["edgeSmoothing"] as? NSNumber)?.floatValue ?? 0.5
      let fps = (args["targetFps"] as? NSNumber)?.intValue ?? 30
      frameProcessor?.setQuality(segmentationWidth: segW, edgeSmoothing: edgeSm, targetFps: fps)
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

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
