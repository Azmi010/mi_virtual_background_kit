import Foundation
import WebRTC

/// Person mask: one alpha byte per pixel, 255 = person, 0 = background.
///
/// Mirrors Android's PersonMask (ADR 0001 §3) with camera rotation metadata (T4.4).
public struct PersonMask {
    public let alpha: [UInt8]
    public let width: Int
    public let height: Int
    public let rotation: RTCVideoRotation

    public init(alpha: [UInt8], width: Int, height: Int, rotation: RTCVideoRotation = ._0) {
        self.alpha = alpha
        self.width = width
        self.height = height
        self.rotation = rotation
    }

    /// Number of detected person pixels (alpha != 0).
    public var personPixelCount: Int {
        var count = 0
        for byte in alpha where byte != 0 {
            count += 1
        }
        return count
    }
}

