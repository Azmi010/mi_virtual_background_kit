import Foundation

/// FR-08: Errors originating from the segmentation pipeline.
public enum SegmentationError: Error, LocalizedError, Equatable {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case segmentationFailed(String)
    case noMaskProduced
    case invalidDimensions(Int, Int)
    case bufferConversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "Segmentation model '\(name)' not found in bundle or resources"
        case .modelLoadFailed(let reason):
            return "Failed to load segmentation model: \(reason)"
        case .segmentationFailed(let reason):
            return "Segmentation failed: \(reason)"
        case .noMaskProduced:
            return "Segmentation produced no mask"
        case .invalidDimensions(let width, let height):
            return "Invalid mask dimensions \(width)x\(height)"
        case .bufferConversionFailed(let reason):
            return "Buffer conversion failed: \(reason)"
        }
    }
}

