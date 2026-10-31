import Flutter
import UIKit
import XCTest

@testable import mi_virtual_background_kit

class MockSegmenter: MaskSegmenter {
  var closeCalled = false
  func segment(image: UIImage) throws -> PersonMask {
    return PersonMask(alpha: [255], width: 1, height: 1)
  }
  func segment(pixelBuffer: CVPixelBuffer) throws -> PersonMask {
    return PersonMask(alpha: [255], width: 1, height: 1)
  }
  func segment(pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation) throws -> PersonMask {
    return PersonMask(alpha: [255], width: 1, height: 1, rotation: rotation)
  }
  func segment(pixelBuffer: CVPixelBuffer, rotation: Int32) throws -> PersonMask {
    return PersonMask(alpha: [255], width: 1, height: 1)
  }
  func close() {
    closeCalled = true
  }
}

class RunnerTests: XCTestCase {

  func testGetPlatformVersion() {
    let plugin = MiVirtualBackgroundKitPlugin()

    let call = FlutterMethodCall(methodName: "getPlatformVersion", arguments: [])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! String, "iOS " + UIDevice.current.systemVersion)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  // MARK: - FrameProcessor Tests

  func testFrameProcessorInitialStateAndRelease() {
    let processor = FrameProcessor()
    XCTAssertEqual(processor.frameCount, 0)
    XCTAssertEqual(processor.lastWidth, 0)
    XCTAssertEqual(processor.lastHeight, 0)
    XCTAssertEqual(processor.lastRotation, 0)
    XCTAssertEqual(processor.bufferType, "")

    processor.release()
    XCTAssertEqual(processor.frameCount, 0)
  }

  func testAttachWithoutTrackIdErrorsInvalidTrack() {
    let plugin = MiVirtualBackgroundKitPlugin()
    let call = FlutterMethodCall(methodName: "attach", arguments: nil)

    let exp = expectation(description: "must return error")
    plugin.handle(call) { result in
      guard let error = result as? FlutterError else {
        XCTFail("Expected FlutterError, got \(String(describing: result))")
        return
      }
      XCTAssertEqual(error.code, "invalidTrack")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testAttachEmptyTrackIdReturnsInvalidTrack() {
    let plugin = MiVirtualBackgroundKitPlugin()
    let call = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "   "])

    let exp = expectation(description: "empty trackId error")
    plugin.handle(call) { result in
      guard let err = result as? FlutterError else {
        XCTFail("Expected FlutterError, got \(String(describing: result))")
        return
      }
      XCTAssertEqual(err.code, "invalidTrack")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testAttachWithNonExistentTrackErrorsInvalidTrack() {
    let plugin = MiVirtualBackgroundKitPlugin()
    let call = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "unknown_track_123"])

    let exp = expectation(description: "must return error")
    plugin.handle(call) { result in
      guard let error = result as? FlutterError else {
        XCTFail("Expected FlutterError, got \(String(describing: result))")
        return
      }
      XCTAssertEqual(error.code, "invalidTrack")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testDetachWithoutAttachIsIdempotentSuccess() {
    let plugin = MiVirtualBackgroundKitPlugin()
    let call = FlutterMethodCall(methodName: "detach", arguments: nil)

    let exp = expectation(description: "must succeed")
    plugin.handle(call) { result in
      XCTAssertNil(result)
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testDisposeIsIdempotentSuccess() {
    let plugin = MiVirtualBackgroundKitPlugin()
    let call = FlutterMethodCall(methodName: "dispose", arguments: nil)

    let exp = expectation(description: "must succeed")
    plugin.handle(call) { result in
      XCTAssertNil(result)
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testIsSupportedChecker() {
    let plugin = MiVirtualBackgroundKitPlugin()

    // Default call
    let call = FlutterMethodCall(methodName: "isSupported", arguments: nil)
    let exp1 = expectation(description: "default isSupported")
    plugin.handle(call) { result in
      XCTAssertNotNil(result as? Bool)
      exp1.fulfill()
    }

    // Forced true
    plugin.isSupportedChecker = { true }
    let exp2 = expectation(description: "isSupported true")
    plugin.handle(call) { result in
      XCTAssertEqual(result as? Bool, true)
      exp2.fulfill()
    }

    // Forced false
    plugin.isSupportedChecker = { false }
    let exp3 = expectation(description: "isSupported false")
    plugin.handle(call) { result in
      XCTAssertEqual(result as? Bool, false)
      exp3.fulfill()
    }

    waitForExpectations(timeout: 1)
  }

  func testEventChannelStreamHandler() {
    let plugin = MiVirtualBackgroundKitPlugin()
    var events: [String] = []

    let err = plugin.onListen(withArguments: nil) { event in
      if let status = event as? String {
        events.append(status)
      }
    }
    XCTAssertNil(err)
    XCTAssertEqual(events, ["idle"])

    plugin.updateStatus("initializing")
    plugin.updateStatus("active")
    plugin.updateStatus("error")
    plugin.updateStatus("idle")

    XCTAssertEqual(events, ["idle", "initializing", "active", "error", "idle"])

    let cancelErr = plugin.onCancel(withArguments: nil)
    XCTAssertNil(cancelErr)

    // Updating status after cancel does not append
    plugin.updateStatus("active")
    XCTAssertEqual(events.count, 5)
  }

  func testAttachAndDetachLifecycle() {
    let plugin = MiVirtualBackgroundKitPlugin()
    var statuses: [String] = []
    _ = plugin.onListen(withArguments: nil) { event in
      if let s = event as? String { statuses.append(s) }
    }

    var detachedTrack: Any? = nil
    plugin.trackAttacher = { _, _ in
      return NSObject()
    }
    plugin.trackDetacher = { track, _ in
      detachedTrack = track
    }
    plugin.frameProcessorFactory = { onStatus in
      return FrameProcessor(segmenterProvider: { MockSegmenter() }, onStatusChange: onStatus)
    }

    let attachCall = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "cam_track_1"])
    let expAttach = expectation(description: "attach success")
    plugin.handle(attachCall) { result in
      XCTAssertNil(result)
      expAttach.fulfill()
    }

    waitForExpectations(timeout: 1)
    XCTAssertEqual(statuses, ["idle", "initializing", "active"])

    let detachCall = FlutterMethodCall(methodName: "detach", arguments: nil)
    let expDetach = expectation(description: "detach success")
    plugin.handle(detachCall) { result in
      XCTAssertNil(result)
      expDetach.fulfill()
    }

    waitForExpectations(timeout: 1)
    XCTAssertNotNil(detachedTrack)
    XCTAssertEqual(statuses.last, "idle")
  }

  func testReattachReplacesOldProcessor() {
    let plugin = MiVirtualBackgroundKitPlugin()
    var detachCount = 0
    plugin.trackAttacher = { _, _ in NSObject() }
    plugin.trackDetacher = { _, _ in detachCount += 1 }
    plugin.frameProcessorFactory = { onStatus in
      FrameProcessor(segmenterProvider: { MockSegmenter() }, onStatusChange: onStatus)
    }

    let call1 = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "track_1"])
    plugin.handle(call1) { _ in }

    XCTAssertEqual(detachCount, 0)

    let call2 = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "track_2"])
    plugin.handle(call2) { _ in }

    XCTAssertEqual(detachCount, 1)
  }

  func testAttachAndDetach_100Times_completesWithoutLeaksOrErrors() {
    let plugin = MiVirtualBackgroundKitPlugin()
    let dummyTrack = NSObject()
    var attachCount = 0
    var detachCount = 0

    plugin.trackAttacher = { _, _ in
      attachCount += 1
      return dummyTrack
    }
    plugin.trackDetacher = { _, _ in
      detachCount += 1
    }
    plugin.frameProcessorFactory = { onStatus in
      FrameProcessor(segmenterProvider: { MockSegmenter() }, onStatusChange: onStatus)
    }

    for i in 1...100 {
      let attachCall = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "track-\(i)"])
      let expAttach = expectation(description: "attach \(i)")
      plugin.handle(attachCall) { result in
        XCTAssertNil(result)
        expAttach.fulfill()
      }
      XCTAssertEqual(plugin.currentStatus, "active")

      let detachCall = FlutterMethodCall(methodName: "detach", arguments: nil)
      let expDetach = expectation(description: "detach \(i)")
      plugin.handle(detachCall) { result in
        XCTAssertNil(result)
        expDetach.fulfill()
      }
      XCTAssertEqual(plugin.currentStatus, "idle")
    }

    waitForExpectations(timeout: 5)
    XCTAssertEqual(attachCount, 100)
    XCTAssertEqual(detachCount, 100)
  }

  func testDispose_cleansUpAttachedTrackAndProcessor() {
    let plugin = MiVirtualBackgroundKitPlugin()
    let dummyTrack = NSObject()
    var detached = false

    plugin.trackAttacher = { _, _ in dummyTrack }
    plugin.trackDetacher = { _, _ in detached = true }
    plugin.frameProcessorFactory = { onStatus in
      FrameProcessor(segmenterProvider: { MockSegmenter() }, onStatusChange: onStatus)
    }

    let attachCall = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "track-1"])
    let expAttach = expectation(description: "attach")
    plugin.handle(attachCall) { _ in expAttach.fulfill() }
    waitForExpectations(timeout: 1)
    XCTAssertEqual(plugin.currentStatus, "active")

    let disposeCall = FlutterMethodCall(methodName: "dispose", arguments: nil)
    let expDispose = expectation(description: "dispose")
    plugin.handle(disposeCall) { result in
      XCTAssertNil(result)
      expDispose.fulfill()
    }
    waitForExpectations(timeout: 1)

    XCTAssertTrue(detached)
    XCTAssertEqual(plugin.currentStatus, "idle")

    // Second dispose is idempotent
    let expDispose2 = expectation(description: "dispose2")
    plugin.handle(disposeCall) { result in
      XCTAssertNil(result)
      expDispose2.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testFrameProcessorReleaseIsIdempotent() throws {
    let mockSeg = MockSegmenter()
    let processor = FrameProcessor(segmenterProvider: { mockSeg })

    try processor.setBlurEffect(radius: 12.0)
    XCTAssertNotNil(processor.currentEffect)

    // First release
    processor.release()
    XCTAssertNil(processor.currentEffect)
    XCTAssertTrue(mockSeg.closeCalled)

    // Second release (idempotent)
    processor.release()
    XCTAssertNil(processor.currentEffect)
  }

  func testFrameProcessorRuntimeEffectSwitching() throws {
    let processor = FrameProcessor(segmenterProvider: { MockSegmenter() })

    // 1. Initial: no effect
    XCTAssertNil(processor.currentEffect)

    // 2. Switch to Blur
    try processor.setBlurEffect(radius: 15.0)
    if case .blur(let r) = processor.currentEffect {
      XCTAssertEqual(r, 15.0)
    } else {
      XCTFail("Expected blur effect")
    }

    // 3. Switch to Color
    try processor.setColorEffect(color: 0xFF00FF00)
    if case .color(let c) = processor.currentEffect {
      XCTAssertEqual(c, 0xFF00FF00)
    } else {
      XCTFail("Expected color effect")
    }

    // 4. Switch to Image
    let size = CGSize(width: 4, height: 4)
    UIGraphicsBeginImageContext(size)
    let testImg = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    UIGraphicsEndImageContext()
    try processor.setImageEffect(image: testImg, fit: "contain")
    if case .image(_, let fit) = processor.currentEffect {
      XCTAssertEqual(fit, "contain")
    } else {
      XCTFail("Expected image effect")
    }

    // 5. Clear effect
    processor.clearEffect()
    XCTAssertNil(processor.currentEffect)

    processor.release()
  }

  func testGpuCompositorClearMask() {
    let compositor = GpuCompositor()
    let mask = PersonMask(alpha: [255, 0, 0, 255], width: 2, height: 2)
    compositor.uploadMask(mask)
    XCTAssertTrue(compositor.hasMask)

    compositor.clearMask()
    XCTAssertFalse(compositor.hasMask)
  }

  func testGpuCompositorReleaseIsIdempotent() {
    let compositor = GpuCompositor()
    let mask = PersonMask(alpha: [255, 0, 0, 255], width: 2, height: 2)
    compositor.uploadMask(mask)
    XCTAssertTrue(compositor.hasMask)

    // First release
    compositor.release()
    XCTAssertFalse(compositor.hasMask)

    // Second release (idempotent)
    compositor.release()
    XCTAssertFalse(compositor.hasMask)
  }

  // MARK: - GpuCompositor & Compositing Tests

  func testGpuCompositorInitialStateAndUploadMask() {
    let compositor = GpuCompositor()
    XCTAssertFalse(compositor.hasMask)

    let mask = PersonMask(alpha: [255, 0, 0, 255], width: 2, height: 2)
    compositor.uploadMask(mask)
    XCTAssertTrue(compositor.hasMask)

    compositor.release()
    XCTAssertFalse(compositor.hasMask)
  }

  func testPersonMaskWithRotation() {
    let mask = PersonMask(alpha: [255, 0], width: 2, height: 1, rotation: ._90)
    XCTAssertEqual(mask.rotation, ._90)
    XCTAssertEqual(mask.width, 2)
    XCTAssertEqual(mask.height, 1)
    XCTAssertEqual(mask.personPixelCount, 1)
  }

  func testGpuCompositorUploadMaskWithRotations() {
    let compositor = GpuCompositor()
    let mask = PersonMask(alpha: [255, 0, 0, 255], width: 2, height: 2)

    compositor.uploadMask(mask, rotation: 90)
    XCTAssertTrue(compositor.hasMask)

    compositor.uploadMask(mask, rotation: 180)
    XCTAssertTrue(compositor.hasMask)

    compositor.uploadMask(mask, rotation: 270)
    XCTAssertTrue(compositor.hasMask)

    compositor.uploadMask(mask, rotation: 0)
    XCTAssertTrue(compositor.hasMask)

    compositor.release()
    XCTAssertFalse(compositor.hasMask)
  }

  func testGpuCompositorUploadImage() {
    let compositor = GpuCompositor()
    let size = CGSize(width: 8, height: 8)
    UIGraphicsBeginImageContext(size)
    UIColor.blue.setFill()
    UIRectFill(CGRect(origin: .zero, size: size))
    let testImg = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    UIGraphicsEndImageContext()

    compositor.uploadImage(testImg)
    compositor.release()
    XCTAssertFalse(compositor.hasMask)
  }

  func testFrameProcessorEffectTransitions() throws {
    let processor = FrameProcessor(segmenterProvider: { MockSegmenter() })
    XCTAssertNil(processor.currentEffect)

    try processor.setBlurEffect(radius: 12.0)
    if case .blur(let radius) = processor.currentEffect {
      XCTAssertEqual(radius, 12.0)
    } else {
      XCTFail("Expected .blur(12.0)")
    }

    try processor.setColorEffect(color: 0xFF112233)
    if case .color(let color) = processor.currentEffect {
      XCTAssertEqual(color, 0xFF112233)
    } else {
      XCTFail("Expected .color(0xFF112233)")
    }

    let size = CGSize(width: 4, height: 4)
    UIGraphicsBeginImageContext(size)
    let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    UIGraphicsEndImageContext()

    try processor.setImageEffect(image: img, fit: "contain")
    if case .image(_, let fit) = processor.currentEffect {
      XCTAssertEqual(fit, "contain")
    } else {
      XCTFail("Expected .image(_, fit: contain)")
    }

    processor.clearEffect()
    XCTAssertNil(processor.currentEffect)

    processor.release()
  }

  func testIsSupportedTrueAndFalse() {
    let plugin = MiVirtualBackgroundKitPlugin()

    // Test true
    plugin.isSupportedChecker = { true }
    let callTrue = FlutterMethodCall(methodName: "isSupported", arguments: nil)
    let expTrue = expectation(description: "isSupported true")
    plugin.handle(callTrue) { result in
      XCTAssertEqual(result as? Bool, true)
      expTrue.fulfill()
    }

    // Test false
    plugin.isSupportedChecker = { false }
    let callFalse = FlutterMethodCall(methodName: "isSupported", arguments: nil)
    let expFalse = expectation(description: "isSupported false")
    plugin.handle(callFalse) { result in
      XCTAssertEqual(result as? Bool, false)
      expFalse.fulfill()
    }

    waitForExpectations(timeout: 1)
  }

  func testEventChannelStatusStreamLifecycle() {
    let plugin = MiVirtualBackgroundKitPlugin()
    var events: [String] = []

    let err = plugin.onListen(withArguments: nil) { event in
      if let status = event as? String {
        events.append(status)
      }
    }
    XCTAssertNil(err)
    XCTAssertEqual(events, ["idle"])

    plugin.updateStatus("initializing")
    plugin.updateStatus("active")
    plugin.updateStatus("error")
    plugin.updateStatus("idle")

    XCTAssertEqual(events, ["idle", "initializing", "active", "error", "idle"])

    let cancelErr = plugin.onCancel(withArguments: nil)
    XCTAssertNil(cancelErr)

    // Updating status after cancel does not send to sink
    plugin.updateStatus("active")
    XCTAssertEqual(events.count, 5)
  }

  func testAttachAndDetachWithMockTrack() {
    let plugin = MiVirtualBackgroundKitPlugin()
    var statusUpdates: [String] = []
    _ = plugin.onListen(withArguments: nil) { event in
      if let s = event as? String { statusUpdates.append(s) }
    }

    var attachedDelegate: ExternalVideoProcessingDelegate?
    var detachedDelegate: ExternalVideoProcessingDelegate?
    let mockTrack = NSObject()

    plugin.trackAttacher = { trackId, delegate in
      attachedDelegate = delegate
      return mockTrack
    }
    plugin.trackDetacher = { track, delegate in
      detachedDelegate = delegate
    }

    let attachCall = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "track_42"])
    let expAttach = expectation(description: "attach succeeds")
    plugin.handle(attachCall) { result in
      XCTAssertNil(result)
      expAttach.fulfill()
    }
    waitForExpectations(timeout: 1)

    XCTAssertNotNil(attachedDelegate)
    XCTAssertEqual(plugin.currentStatus, "active")
    XCTAssertEqual(statusUpdates, ["idle", "initializing", "active"])

    // Detach
    let detachCall = FlutterMethodCall(methodName: "detach", arguments: nil)
    let expDetach = expectation(description: "detach succeeds")
    plugin.handle(detachCall) { result in
      XCTAssertNil(result)
      expDetach.fulfill()
    }
    waitForExpectations(timeout: 1)

    XCTAssertNotNil(detachedDelegate)
    XCTAssertEqual(plugin.currentStatus, "idle")
    XCTAssertEqual(statusUpdates, ["idle", "initializing", "active", "idle"])
  }

  func testSetEffectModelLoadFailedReturnsError() {
    let plugin = MiVirtualBackgroundKitPlugin()
    plugin.trackAttacher = { _, _ in NSObject() }
    plugin.frameProcessorFactory = { onStatus in
      FrameProcessor(
        segmenterProvider: {
          throw SegmentationError.modelLoadFailed("Corrupt model file")
        },
        onStatusChange: onStatus
      )
    }

    // Attach first so frameProcessor is created with failing segmenter
    let attachCall = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "t1"])
    let expAttach = expectation(description: "attach")
    plugin.handle(attachCall) { _ in expAttach.fulfill() }
    waitForExpectations(timeout: 1)

    // Call setEffect blur
    let effectCall = FlutterMethodCall(methodName: "setEffect", arguments: ["type": "blur", "radius": 10.0])
    let expEffect = expectation(description: "effect should fail with modelLoadFailed")
    plugin.handle(effectCall) { result in
      guard let err = result as? FlutterError else {
        XCTFail("Expected FlutterError, got \(String(describing: result))")
        return
      }
      XCTAssertEqual(err.code, "modelLoadFailed")
      expEffect.fulfill()
    }
    waitForExpectations(timeout: 1)
    XCTAssertEqual(plugin.currentStatus, "error")
  }

  func testSetEffectImageSuccessWithMockDecoder() {
    let plugin = MiVirtualBackgroundKitPlugin()
    plugin.trackAttacher = { _, _ in NSObject() }
    plugin.frameProcessorFactory = { onStatus in
      FrameProcessor(segmenterProvider: { MockSegmenter() }, onStatusChange: onStatus)
    }

    let size = CGSize(width: 10, height: 10)
    UIGraphicsBeginImageContext(size)
    let testImg = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    UIGraphicsEndImageContext()

    plugin.imageDecoder = { _, _ in testImg }

    let attachCall = FlutterMethodCall(methodName: "attach", arguments: ["trackId": "t1"])
    let expAttach = expectation(description: "attach")
    plugin.handle(attachCall) { _ in expAttach.fulfill() }
    waitForExpectations(timeout: 1)

    let imgCall = FlutterMethodCall(methodName: "setEffect", arguments: [
      "type": "image",
      "fit": "contain",
      "sourceType": "asset",
      "data": "assets/bg.png"
    ])
    let expImg = expectation(description: "image effect succeeds")
    plugin.handle(imgCall) { result in
      XCTAssertNil(result)
      expImg.fulfill()
    }
    waitForExpectations(timeout: 1)
    XCTAssertEqual(plugin.currentStatus, "active")
  }

  func testPluginSetEffectBlurAndColorAndNone() {
    let plugin = MiVirtualBackgroundKitPlugin()

    // Missing type arg -> bad_args
    let badCall = FlutterMethodCall(methodName: "setEffect", arguments: ["radius": 10])
    let expBad = expectation(description: "bad args error")
    plugin.handle(badCall) { result in
      guard let err = result as? FlutterError else {
        XCTFail("Expected FlutterError, got \(String(describing: result))")
        return
      }
      XCTAssertEqual(err.code, "bad_args")
      expBad.fulfill()
    }

    // Blur call
    let blurCall = FlutterMethodCall(methodName: "setEffect", arguments: ["type": "blur", "radius": 15.0])
    let expBlur = expectation(description: "blur success")
    plugin.handle(blurCall) { result in
      XCTAssertNil(result)
      expBlur.fulfill()
    }

    // Color call
    let colorCall = FlutterMethodCall(methodName: "setEffect", arguments: ["type": "color", "color": 0xFF00FF00])
    let expColor = expectation(description: "color success")
    plugin.handle(colorCall) { result in
      XCTAssertNil(result)
      expColor.fulfill()
    }

    // None call
    let noneCall = FlutterMethodCall(methodName: "setEffect", arguments: ["type": "none"])
    let expNone = expectation(description: "none success")
    plugin.handle(noneCall) { result in
      XCTAssertNil(result)
      expNone.fulfill()
    }

    // Unsupported type call
    let unknownCall = FlutterMethodCall(methodName: "setEffect", arguments: ["type": "unknown_type"])
    let expUnknown = expectation(description: "unknown not implemented")
    plugin.handle(unknownCall) { result in
      XCTAssertTrue(result as? NSObject == FlutterMethodNotImplemented)
      expUnknown.fulfill()
    }

    waitForExpectations(timeout: 1)
  }

  func testPluginSetEffectInvalidImage() {
    let plugin = MiVirtualBackgroundKitPlugin()
    let call = FlutterMethodCall(methodName: "setEffect", arguments: [
      "type": "image",
      "sourceType": "invalid_source",
      "data": "xyz"
    ])
    let exp = expectation(description: "invalidImage error")
    plugin.handle(call) { result in
      guard let err = result as? FlutterError else {
        XCTFail("Expected FlutterError, got \(String(describing: result))")
        return
      }
      XCTAssertEqual(err.code, "invalidImage")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  // MARK: - MaskCodec Tests

  func testUInt8CategoryMaskConversion() throws {
    // MediaPipe category mask: person=0, background=255
    let uint8Mask: [UInt8] = [0, 255, 0, 1, 255, 0]
    var out: [UInt8] = []

    try MaskCodec.toAlpha(uint8Data: uint8Mask, width: 3, height: 2, out: &out)

    XCTAssertEqual(out.count, 6)
    // 0 -> 255, anything else -> 0
    XCTAssertEqual(out, [255, 0, 255, 0, 0, 255])
  }

  func testFloat32ConfidenceMaskConversion() throws {
    // Float confidence mask: >= 0.5 is person
    let floatMask: [Float] = [0.0, 0.49, 0.5, 0.9, 1.0, 0.2]
    var out: [UInt8] = []

    try MaskCodec.toAlpha(float32Data: floatMask, width: 3, height: 2, out: &out)

    XCTAssertEqual(out.count, 6)
    XCTAssertEqual(out, [0, 0, 255, 255, 255, 0])
  }

  func testInvalidDimensionsThrowError() {
    var out: [UInt8] = []
    XCTAssertThrowsError(try MaskCodec.toAlpha(uint8Data: [0], width: 0, height: 1, out: &out)) { error in
      guard let segError = error as? SegmentationError,
            case .invalidDimensions(0, 1) = segError else {
        XCTFail("Expected invalidDimensions(0, 1), got \(error)")
        return
      }
    }

    XCTAssertThrowsError(try MaskCodec.toAlpha(float32Data: [0.5], width: -1, height: 2, out: &out)) { error in
      guard let segError = error as? SegmentationError,
            case .invalidDimensions(-1, 2) = segError else {
        XCTFail("Expected invalidDimensions(-1, 2), got \(error)")
        return
      }
    }
  }

  func testBufferTooSmallThrowsError() {
    var out: [UInt8] = []
    XCTAssertThrowsError(try MaskCodec.toAlpha(uint8Data: [0, 255], width: 2, height: 2, out: &out)) { error in
      guard let segError = error as? SegmentationError,
            case .segmentationFailed = segError else {
        XCTFail("Expected segmentationFailed, got \(error)")
        return
      }
    }
  }

  func testReusableBufferAllocation() throws {
    var out = [UInt8](repeating: 0, count: 2)
    let mask: [UInt8] = [0, 255, 255, 0]

    try MaskCodec.toAlpha(uint8Data: mask, width: 2, height: 2, out: &out)

    XCTAssertEqual(out.count, 4)
    XCTAssertEqual(out, [255, 0, 0, 255])
  }

  // MARK: - Segmenter Tests

  private func findTestImage() -> UIImage? {
    let testBundle = Bundle(for: type(of: self))
    if let path = testBundle.path(forResource: "person_frame", ofType: "png"),
       let image = UIImage(contentsOfFile: path) {
      return image
    }

    let candidates = [
      "RunnerTests/person_frame.png",
      "example/ios/RunnerTests/person_frame.png",
      "../RunnerTests/person_frame.png"
    ]
    let fileManager = FileManager.default
    let currentDir = fileManager.currentDirectoryPath
    for rel in candidates {
      let absPath = (currentDir as NSString).appendingPathComponent(rel)
      if fileManager.fileExists(atPath: absPath), let image = UIImage(contentsOfFile: absPath) {
        return image
      }
    }
    return nil
  }

  private func findModelFile() -> String? {
    if let resolved = Segmenter.resolveModelPath() {
      return resolved
    }
    let candidates = [
      "ios/mi_virtual_background_kit/Sources/mi_virtual_background_kit/Resources/selfie_segmenter.tflite",
      "../../ios/mi_virtual_background_kit/Sources/mi_virtual_background_kit/Resources/selfie_segmenter.tflite",
      "mi_virtual_background_kit/Sources/mi_virtual_background_kit/Resources/selfie_segmenter.tflite"
    ]
    let fileManager = FileManager.default
    let currentDir = fileManager.currentDirectoryPath
    for rel in candidates {
      let absPath = (currentDir as NSString).appendingPathComponent(rel)
      if fileManager.fileExists(atPath: absPath) {
        return absPath
      }
    }
    return nil
  }

  func testModelNotFoundThrowsError() {
    XCTAssertThrowsError(try Segmenter(modelPath: "/nonexistent/path/model.tflite")) { error in
      guard let segError = error as? SegmentationError,
            case .modelNotFound = segError else {
        XCTFail("Expected modelNotFound error, got \(error)")
        return
      }
    }
  }

  func testPersonMaskProducedForOneFrame() throws {
    guard let testImage = findTestImage() else {
      XCTFail("Could not locate person_frame.png test asset")
      return
    }

    let modelPath = findModelFile()
    XCTAssertNotNil(modelPath, "Could not locate selfie_segmenter.tflite")

    let segmenter = try Segmenter(modelPath: modelPath)
    defer { segmenter.close() }

    let mask = try segmenter.segment(image: testImage)

    XCTAssertGreaterThan(mask.width, 0)
    XCTAssertGreaterThan(mask.height, 0)
    XCTAssertEqual(mask.alpha.count, mask.width * mask.height)

    let personPixels = mask.personPixelCount
    let totalPixels = mask.alpha.count

    // Verify that a substantial amount of person pixels are detected (> 5% of frame)
    XCTAssertGreaterThan(
      personPixels,
      totalPixels / 20,
      "Expected person pixels > \(totalPixels / 20), got \(personPixels) out of \(totalPixels)"
    )
  }
}
