import Foundation

/// Converts a MediaPipe category mask into alpha bytes (255 = person, 0 = background).
///
/// selfie_segmenter.tflite encodes UINT8 person=0, background=255 — verified
/// by histogram on frames with and without a person (ADR 0001 §3). A FLOAT32
/// confidence mask uses person >= 0.5. The predicate must not be inverted:
/// `value != 0` marks the background.
public enum MaskCodec {

    /// Converts a raw UInt8 pointer mask (UINT8 category mask: 0=person) to alpha bytes in `out`.
    public static func toAlpha(
        uint8Pointer: UnsafePointer<UInt8>,
        count: Int,
        width: Int,
        height: Int,
        out: inout [UInt8]
    ) throws {
        guard width > 0, height > 0 else {
            throw SegmentationError.invalidDimensions(width, height)
        }
        let pixels = width * height
        guard count >= pixels else {
            throw SegmentationError.segmentationFailed(
                "Input buffer count \(count) is less than required pixels \(pixels)"
            )
        }

        if out.count < pixels {
            out = [UInt8](repeating: 0, count: pixels)
        }

        for i in 0..<pixels {
            out[i] = (uint8Pointer[i] == 0) ? 255 : 0
        }
    }

    /// Converts a raw Float32 pointer mask (confidence mask: >= 0.5 person) to alpha bytes in `out`.
    public static func toAlpha(
        float32Pointer: UnsafePointer<Float>,
        count: Int,
        width: Int,
        height: Int,
        out: inout [UInt8]
    ) throws {
        guard width > 0, height > 0 else {
            throw SegmentationError.invalidDimensions(width, height)
        }
        let pixels = width * height
        guard count >= pixels else {
            throw SegmentationError.segmentationFailed(
                "Input buffer count \(count) is less than required pixels \(pixels)"
            )
        }

        if out.count < pixels {
            out = [UInt8](repeating: 0, count: pixels)
        }

        for i in 0..<pixels {
            out[i] = (float32Pointer[i] >= 0.5) ? 255 : 0
        }
    }

    /// Converts a UInt8 array mask to alpha bytes in `out`.
    public static func toAlpha(
        uint8Data: [UInt8],
        width: Int,
        height: Int,
        out: inout [UInt8]
    ) throws {
        try uint8Data.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SegmentationError.segmentationFailed("Empty input buffer pointer")
            }
            try toAlpha(
                uint8Pointer: baseAddress,
                count: buffer.count,
                width: width,
                height: height,
                out: &out
            )
        }
    }

    /// Converts a Float32 array mask to alpha bytes in `out`.
    public static func toAlpha(
        float32Data: [Float],
        width: Int,
        height: Int,
        out: inout [UInt8]
    ) throws {
        try float32Data.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SegmentationError.segmentationFailed("Empty input buffer pointer")
            }
            try toAlpha(
                float32Pointer: baseAddress,
                count: buffer.count,
                width: width,
                height: height,
                out: &out
            )
        }
    }
}

