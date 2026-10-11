import Foundation

/// Explicit decoded-pixel and IOSurface budget. Dimensions from files/XPC are
/// checked before converting or multiplying, including alignment padding.
enum WallpaperSnapshotPixelBudget {
    static let maximumPixelBytes = 32 * 1024 * 1024
    static let maximumDimension = 4096
    // Reserve for a worst-case 16-byte decoded pixel, including common strides.
    static let maximumVideoImageDimension = 1440

    struct Layout: Equatable, Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let allocationBytes: Int
    }

    static func layout(width: Double, height: Double, decodedBytesPerPixel: Int = 4,
                       rowAlignment: Int = 16, allocationAlignment: Int = 1) -> Layout? {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              decodedBytesPerPixel >= 4, decodedBytesPerPixel <= 16,
              rowAlignment >= 1, rowAlignment <= maximumPixelBytes,
              allocationAlignment >= 1, allocationAlignment <= maximumPixelBytes else { return nil }
        let pixels = width * height
        guard pixels.isFinite, pixels > 0 else { return nil }
        let scale = min(min(1.0, Double(maximumDimension) / width),
                        min(Double(maximumDimension) / height,
                            sqrt(Double(maximumPixelBytes / decodedBytesPerPixel) / pixels)))
        var targetWidth = max(1, Int((width * scale).rounded(.down)))
        var targetHeight = max(1, Int((height * scale).rounded(.down)))
        while targetWidth > 0, targetHeight > 0 {
            let row = ((targetWidth * 4 + rowAlignment - 1) / rowAlignment) * rowAlignment
            let rawBytes = row * targetHeight
            let bytes = ((rawBytes + allocationAlignment - 1) / allocationAlignment) * allocationAlignment
            if bytes <= maximumPixelBytes {
                return Layout(width: targetWidth, height: targetHeight, bytesPerRow: row, allocationBytes: bytes)
            }
            if targetWidth >= targetHeight { targetWidth -= 1 } else { targetHeight -= 1 }
        }
        return nil
    }

    static func accepts(width: Int, height: Int, bytesPerRow: Int) -> Bool {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              bytesPerRow >= width * 4 else { return false }
        let (bytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        return !overflow && bytes > 0 && bytes <= maximumPixelBytes
    }

    static func acceptsDecodedImage(width: Int, height: Int, bytesPerRow: Int) -> Bool {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              bytesPerRow >= width else { return false }
        let (bytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        return !overflow && bytes > 0 && bytes <= maximumPixelBytes
    }
}
