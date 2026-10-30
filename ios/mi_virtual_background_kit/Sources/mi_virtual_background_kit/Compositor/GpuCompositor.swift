import Foundation
import CoreImage
import CoreVideo
import Metal
import UIKit
import WebRTC

/// Common interface for video frame compositors.
public protocol FrameCompositor: AnyObject {
    var hasMask: Bool { get }
    func uploadMask(_ mask: PersonMask)
    func uploadImage(_ image: UIImage)
    func composeBlur(frame: RTCVideoFrame, radius: Float) -> RTCVideoFrame?
    func composeColor(frame: RTCVideoFrame, color: UInt32) -> RTCVideoFrame?
    func composeImage(frame: RTCVideoFrame, fit: String) -> RTCVideoFrame?
    func release()
}

/// Metal and Core Image GPU compositor for virtual background effects on iOS.
///
/// Runs on the WebRTC capture/processing thread with zero readback overhead:
/// - Core Image processes native CVPixelBuffer textures directly on the GPU.
/// - Gaussian blur with adjustable radius (T4.3, FR-01).
/// - Solid color background with 32-bit ARGB (T4.3, FR-03).
/// - Image background with cover and contain aspect-ratio fits (T4.3, FR-02).
/// - CVPixelBufferPool for zero-allocation rendering per frame.
public class GpuCompositor: FrameCompositor {
    private let ciContext: CIContext
    private var currentMaskImage: CIImage?
    private var maskWidth: Int = 0
    private var maskHeight: Int = 0
    private var currentBackgroundImage: CIImage?
    private var backgroundImageSize: CGSize = .zero

    private var bufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private var poolFormat: OSType = 0
    private let lock = NSLock()

    public var hasMask: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentMaskImage != nil
    }

    public init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: metalDevice, options: [
                .useSoftwareRenderer: false,
                .cacheIntermediates: false,
            ])
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    public func uploadMask(_ mask: PersonMask) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data(mask.alpha)
        let maskCi = CIImage(
            bitmapData: data,
            bytesPerRow: mask.width,
            size: CGSize(width: mask.width, height: mask.height),
            format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        self.currentMaskImage = maskCi
        self.maskWidth = mask.width
        self.maskHeight = mask.height
    }

    public func uploadImage(_ image: UIImage) {
        lock.lock()
        defer { lock.unlock() }
        if let cgImage = image.cgImage {
            self.currentBackgroundImage = CIImage(cgImage: cgImage)
            self.backgroundImageSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else if let ciImage = image.ciImage {
            self.currentBackgroundImage = ciImage
            self.backgroundImageSize = ciImage.extent.size
        }
    }

    public func composeBlur(frame: RTCVideoFrame, radius: Float) -> RTCVideoFrame? {
        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let pixelBuffer = rtcBuffer.pixelBuffer
        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Generate blurred background
        let clamped = cameraImage.clampedToExtent()
        let blurred = clamped.applyingGaussianBlur(sigma: Double(radius))
        let bgImage = blurred.cropped(to: cameraImage.extent)

        return blendAndRender(cameraImage: cameraImage, bgImage: bgImage, frame: frame, inputBuffer: pixelBuffer)
    }

    public func composeColor(frame: RTCVideoFrame, color: UInt32) -> RTCVideoFrame? {
        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let pixelBuffer = rtcBuffer.pixelBuffer
        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Parse ARGB (32-bit integer from Dart)
        let a = CGFloat((color >> 24) & 0xFF) / 255.0
        let r = CGFloat((color >> 16) & 0xFF) / 255.0
        let g = CGFloat((color >> 8) & 0xFF) / 255.0
        let b = CGFloat(color & 0xFF) / 255.0
        let ciColor = CIColor(red: r, green: g, blue: b, alpha: a)
        let bgImage = CIImage(color: ciColor).cropped(to: cameraImage.extent)

        return blendAndRender(cameraImage: cameraImage, bgImage: bgImage, frame: frame, inputBuffer: pixelBuffer)
    }

    public func composeImage(frame: RTCVideoFrame, fit: String) -> RTCVideoFrame? {
        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let pixelBuffer = rtcBuffer.pixelBuffer
        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)

        lock.lock()
        guard let bgSource = currentBackgroundImage, backgroundImageSize.width > 0, backgroundImageSize.height > 0 else {
            lock.unlock()
            return nil
        }
        let imgSize = backgroundImageSize
        lock.unlock()

        let frameWidth = cameraImage.extent.width
        let frameHeight = cameraImage.extent.height

        let bgImage: CIImage
        if fit == "contain" {
            let scale = min(frameWidth / imgSize.width, frameHeight / imgSize.height)
            let scaledW = imgSize.width * scale
            let scaledH = imgSize.height * scale
            let dx = cameraImage.extent.origin.x + (frameWidth - scaledW) / 2.0
            let dy = cameraImage.extent.origin.y + (frameHeight - scaledH) / 2.0
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
            let scaledImg = bgSource.transformed(by: transform)
            let blackBg = CIImage(color: CIColor.black).cropped(to: cameraImage.extent)
            bgImage = scaledImg.composited(over: blackBg).cropped(to: cameraImage.extent)
        } else {
            // "cover" (default)
            let scale = max(frameWidth / imgSize.width, frameHeight / imgSize.height)
            let scaledW = imgSize.width * scale
            let scaledH = imgSize.height * scale
            let dx = cameraImage.extent.origin.x + (frameWidth - scaledW) / 2.0
            let dy = cameraImage.extent.origin.y + (frameHeight - scaledH) / 2.0
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
            bgImage = bgSource.transformed(by: transform).cropped(to: cameraImage.extent)
        }

        return blendAndRender(cameraImage: cameraImage, bgImage: bgImage, frame: frame, inputBuffer: pixelBuffer)
    }

    private func blendAndRender(
        cameraImage: CIImage,
        bgImage: CIImage,
        frame: RTCVideoFrame,
        inputBuffer: CVPixelBuffer
    ) -> RTCVideoFrame? {
        lock.lock()
        guard let maskCi = currentMaskImage, maskWidth > 0, maskHeight > 0 else {
            lock.unlock()
            // No mask ready yet: passthrough frame
            return frame
        }

        // Scale mask to match camera image extent
        let scaleX = cameraImage.extent.width / CGFloat(maskWidth)
        let scaleY = cameraImage.extent.height / CGFloat(maskHeight)
        let scaledMask = maskCi
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: cameraImage.extent.origin.x, y: cameraImage.extent.origin.y))
        lock.unlock()

        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(cameraImage, forKey: kCIInputImageKey)
        blendFilter.setValue(bgImage, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)

        guard let outputImage = blendFilter.outputImage else { return nil }

        let width = CVPixelBufferGetWidth(inputBuffer)
        let height = CVPixelBufferGetHeight(inputBuffer)
        let format = kCVPixelFormatType_32BGRA

        guard let outputBuffer = getPixelBuffer(width: width, height: height, format: format) else {
            return nil
        }

        ciContext.render(
            outputImage,
            to: outputBuffer,
            bounds: outputImage.extent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let outRtcBuffer = RTCCVPixelBuffer(pixelBuffer: outputBuffer)
        return RTCVideoFrame(buffer: outRtcBuffer, rotation: frame.rotation, timeStampNs: frame.timeStampNs)
    }

    private func getPixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if bufferPool == nil || poolWidth != width || poolHeight != height || poolFormat != format {
            createBufferPool(width: width, height: height, format: format)
        }
        guard let pool = bufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        if status == kCVReturnSuccess, let buffer = pixelBuffer {
            return buffer
        }
        return nil
    }

    private func createBufferPool(width: Int, height: Int, format: OSType) {
        self.bufferPool = nil
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        if status == kCVReturnSuccess {
            self.bufferPool = pool
            self.poolWidth = width
            self.poolHeight = height
            self.poolFormat = format
        }
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        currentMaskImage = nil
        currentBackgroundImage = nil
        bufferPool = nil
    }
}
