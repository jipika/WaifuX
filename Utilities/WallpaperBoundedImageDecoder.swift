import Foundation
import ImageIO

/// Immutable ImageIO output may cross the decode worker boundary. No mutable
/// graphics context or image source escapes the worker.
struct WallpaperDecodedImage: @unchecked Sendable {
    let image: CGImage
    let attempts: Int
}

struct WallpaperImageDecodeFailure: Error, LocalizedError, Sendable {
    let stage: String
    let detail: String
    var errorDescription: String? { "image decode \(stage): \(detail)" }
}

/// Shared by the host preflight, extension rendering and snapshots. The gate
/// limits concurrent decodes, not retained images; callers must run this off main.
/// No UserDefaults, App Group or graphics device is accessed here.
enum WallpaperBoundedImageDecoder {
    static let maximumAttempts = 3
    private static let decodeLock = NSLock()

    static func retryDimensions(initialDimension: Int) -> [Int] {
        guard initialDimension > 0 else { return [] }
        var result: [Int] = []
        var dimension = min(initialDimension, WallpaperSnapshotPixelBudget.maximumDimension)
        for _ in 0..<maximumAttempts {
            result.append(dimension)
            guard dimension > 1 else { break }
            dimension = max(1, dimension / 2)
        }
        return result
    }

    static func decode(url: URL) -> Result<WallpaperDecodedImage, WallpaperImageDecodeFailure> {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        return autoreleasepool {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
                return .failure(.init(stage: "open", detail: url.lastPathComponent))
            }
            return decode(source: source)
        }
    }

    static func decode(data: Data) -> Result<WallpaperDecodedImage, WallpaperImageDecodeFailure> {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        return autoreleasepool {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
                return .failure(.init(stage: "open", detail: "unrecognized image data"))
            }
            return decode(source: source)
        }
    }

    private static func decode(source: CGImageSource) -> Result<WallpaperDecodedImage, WallpaperImageDecodeFailure> {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return .failure(.init(stage: "metadata", detail: "missing pixel dimensions"))
        }
        let depth = min(32, max(8, (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 16))
        let bytesPerPixel = ((depth + 7) / 8) * 4
        // ImageIO's row stride need not match a 16-byte destination bitmap.
        // Budget common decoder alignment conservatively, then verify reality.
        guard let layout = WallpaperSnapshotPixelBudget.layout(
            width: width.doubleValue, height: height.doubleValue,
            decodedBytesPerPixel: bytesPerPixel, rowAlignment: 256
        ) else {
            return .failure(.init(stage: "geometry", detail: "invalid dimensions/depth"))
        }
        var lastFailure = WallpaperImageDecodeFailure(stage: "decode", detail: "no image")
        for (index, dimension) in retryDimensions(initialDimension: max(layout.width, layout.height)).enumerated() {
            let attempt = index + 1
            // A rejected bitmap is released before attempting a smaller one.
            let result: Result<WallpaperDecodedImage, WallpaperImageDecodeFailure> = autoreleasepool {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceShouldAllowFloat: false,
                    kCGImageSourceThumbnailMaxPixelSize: dimension,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return .failure(.init(stage: "decode", detail: "attempt=\(attempt) max=\(dimension) status=\(CGImageSourceGetStatus(source).rawValue)"))
                }
                guard WallpaperSnapshotPixelBudget.acceptsDecodedImage(
                    width: image.width, height: image.height, bytesPerRow: image.bytesPerRow
                ) else {
                    return .failure(.init(stage: "pixel-budget", detail: "attempt=\(attempt) image=\(image.width)x\(image.height) row=\(image.bytesPerRow)"))
                }
                return .success(WallpaperDecodedImage(image: image, attempts: attempt))
            }
            switch result {
            case .success: return result
            case .failure(let failure): lastFailure = failure
            }
        }
        return .failure(lastFailure)
    }
}
