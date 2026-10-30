import Flutter
import UIKit
import XCTest

@testable import mi_virtual_background_kit

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
