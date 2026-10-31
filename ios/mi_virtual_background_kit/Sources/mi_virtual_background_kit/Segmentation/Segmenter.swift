import Foundation
import UIKit
import CoreVideo
import CoreImage
import MediaPipeTasksVision
import WebRTC

/// Common interface for person segmenters on iOS.
public protocol MaskSegmenter: AnyObject {
    func segment(image: UIImage) throws -> PersonMask
    func segment(pixelBuffer: CVPixelBuffer) throws -> PersonMask
    func segment(pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation) throws -> PersonMask
    func segment(pixelBuffer: CVPixelBuffer, rotation: Int32) throws -> PersonMask
    func close()
}

/// Person segmentation with MediaPipe Image Segmenter and the bundled
/// `selfie_segmenter.tflite` model, CPU delegate (ADR 0001 §3).
public class Segmenter: MaskSegmenter {
    public static let modelAssetName = "selfie_segmenter"
    public static let modelAssetExtension = "tflite"

    private var imageSegmenter: ImageSegmenter?
    private var reusableAlphaBuffer: [UInt8] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var isClosed = false

    /// Initializes the segmenter with the bundled model or a custom model path.
    public init(modelPath: String? = nil) throws {
        guard let resolvedPath = Segmenter.resolveModelPath(customPath: modelPath) else {
            throw SegmentationError.modelNotFound("\(Segmenter.modelAssetName).\(Segmenter.modelAssetExtension)")
        }

        let options = ImageSegmenterOptions()
        options.baseOptions.modelAssetPath = resolvedPath
        options.baseOptions.delegate = .CPU
        options.runningMode = .image
        options.shouldOutputCategoryMask = true
        options.shouldOutputConfidenceMasks = false

        do {
            self.imageSegmenter = try ImageSegmenter(options: options)
        } catch {
            throw SegmentationError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Segments a UIImage into a PersonMask.
    public func segment(image: UIImage) throws -> PersonMask {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed, let segmenter = imageSegmenter else {
            throw SegmentationError.segmentationFailed("Segmenter is closed")
        }

        let mpImage: MPImage
        do {
            mpImage = try MPImage(uiImage: image)
        } catch {
            throw SegmentationError.segmentationFailed("Failed to create MPImage from UIImage: \(error)")
        }

        return try processMpImage(mpImage, segmenter: segmenter)
    }

    /// Segments a CVPixelBuffer into a PersonMask directly in camera buffer coordinates.
    /// Handles native BGRA buffers directly or converts YUV/other formats via CoreImage.
    public func segment(pixelBuffer: CVPixelBuffer, rotation: Int32 = 0) throws -> PersonMask {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed, let segmenter = imageSegmenter else {
            throw SegmentationError.segmentationFailed("Segmenter is closed")
        }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let mpImage: MPImage
        if format == kCVPixelFormatType_32BGRA {
            do {
                mpImage = try MPImage(pixelBuffer: pixelBuffer)
            } catch {
                throw SegmentationError.segmentationFailed("Failed to create MPImage from BGRA pixelBuffer: \(error)")
            }
        } else {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                throw SegmentationError.bufferConversionFailed("Failed to create CGImage from pixelBuffer (format \(format))")
            }
            let uiImage = UIImage(cgImage: cgImage)
            do {
                mpImage = try MPImage(uiImage: uiImage)
            } catch {
                throw SegmentationError.segmentationFailed("Failed to create MPImage from converted UIImage: \(error)")
            }
        }

        let mask = try processMpImage(mpImage, segmenter: segmenter)
        let rtcRot = RTCVideoRotation(rawValue: Int(rotation)) ?? ._0
        return PersonMask(alpha: mask.alpha, width: mask.width, height: mask.height, rotation: rtcRot)
    }

    public func segment(pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation) throws -> PersonMask {
        return try segment(pixelBuffer: pixelBuffer, rotation: Int32(rotation.rawValue))
    }

    public func segment(pixelBuffer: CVPixelBuffer) throws -> PersonMask {
        return try segment(pixelBuffer: pixelBuffer, rotation: 0)
    }

    private func processMpImage(_ mpImage: MPImage, segmenter: ImageSegmenter) throws -> PersonMask {
        let result: ImageSegmenterResult
        do {
            result = try segmenter.segment(image: mpImage)
        } catch {
            throw SegmentationError.segmentationFailed(error.localizedDescription)
        }

        guard let categoryMask = result.categoryMask else {
            throw SegmentationError.noMaskProduced
        }

        let width = categoryMask.width
        let height = categoryMask.height

        switch categoryMask.dataType {
        case .uInt8:
            try MaskCodec.toAlpha(
                uint8Pointer: categoryMask.uint8Data,
                count: width * height,
                width: width,
                height: height,
                out: &reusableAlphaBuffer
            )
        case .float32:
            try MaskCodec.toAlpha(
                float32Pointer: categoryMask.float32Data,
                count: width * height,
                width: width,
                height: height,
                out: &reusableAlphaBuffer
            )
        @unknown default:
            try MaskCodec.toAlpha(
                uint8Pointer: categoryMask.uint8Data,
                count: width * height,
                width: width,
                height: height,
                out: &reusableAlphaBuffer
            )
        }

        return PersonMask(alpha: reusableAlphaBuffer, width: width, height: height)
    }

    /// Disposes the underlying segmenter and cleans up resources.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        imageSegmenter = nil
        reusableAlphaBuffer.removeAll(keepingCapacity: false)
    }

    deinit {
        close()
    }

    /// Resolves the file system path for `selfie_segmenter.tflite` across SPM, CocoaPods, and app bundles.
    public static func resolveModelPath(customPath: String? = nil) -> String? {
        if let customPath = customPath {
            return FileManager.default.fileExists(atPath: customPath) ? customPath : nil
        }

        #if SWIFT_PACKAGE
        if let path = Bundle.module.path(forResource: modelAssetName, ofType: modelAssetExtension) {
            return path
        }
        #endif

        let frameworkBundle = Bundle(for: MiVirtualBackgroundKitPlugin.self)
        if let path = frameworkBundle.path(forResource: modelAssetName, ofType: modelAssetExtension) {
            return path
        }

        if let bundleUrl = frameworkBundle.url(forResource: "mi_virtual_background_kit", withExtension: "bundle"),
           let resourceBundle = Bundle(url: bundleUrl),
           let path = resourceBundle.path(forResource: modelAssetName, ofType: modelAssetExtension) {
            return path
        }

        if let path = Bundle.main.path(forResource: modelAssetName, ofType: modelAssetExtension) {
            return path
        }

        if let bundleUrl = Bundle.main.url(forResource: "mi_virtual_background_kit", withExtension: "bundle"),
           let resourceBundle = Bundle(url: bundleUrl),
           let path = resourceBundle.path(forResource: modelAssetName, ofType: modelAssetExtension) {
            return path
        }

        return nil
    }
}

