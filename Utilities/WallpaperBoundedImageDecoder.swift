import Foundation
import ImageIO

/// Immutable ImageIO output may cross the decode worker boundary. No mutable
/// graphics context or image source escapes the worker.
struct WallpaperDecodedImage: @unchecked Sendable {
    let image: CGImage
    /// Original pixel dimensions after the same EXIF transform used by ImageIO's
    /// thumbnail. Center/tile layout must not treat a bounded bitmap as the source.
    let sourceSize: CGSize
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

    private static let containerIntegrityScanLimitBytes = 128 * 1024 * 1024

    /// Fast structural completeness check for JPEG (SOI..EOI) and PNG (magic..IEND).
    /// ImageIO can return `status == .statusComplete` on truncated files while filling missing bottom rows with gray.
    static func isCompleteFile(at url: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0 else { return false }
        let type = CGImageSourceGetType(source) as String?
        return verifyContainerIntegrity(url: url, typeIdentifier: type) == nil
    }

    static func hasCompleteContainerStream(_ data: Data, typeIdentifier: String?) -> Bool {
        switch typeIdentifier {
        case "public.jpeg":
            return hasCompleteJPEGStream(data)
        case "public.png":
            return hasCompletePNGStream(data)
        default:
            return true
        }
    }

    private static func verifyContainerIntegrity(
        url: URL,
        typeIdentifier: String?
    ) -> WallpaperImageDecodeFailure? {
        guard typeIdentifier == "public.jpeg" || typeIdentifier == "public.png" else { return nil }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size > containerIntegrityScanLimitBytes {
            return nil
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .init(stage: "integrity", detail: "unreadable \(typeIdentifier ?? "image")")
        }
        guard hasCompleteContainerStream(data, typeIdentifier: typeIdentifier) else {
            return .init(stage: "integrity", detail: "truncated \(typeIdentifier ?? "image")")
        }
        return nil
    }

    private static func hasCompleteJPEGStream(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let count = raw.count
            guard count >= 4, base[0] == 0xFF, base[1] == 0xD8 else { return false }
            var index = 2
            while index + 1 < count {
                if base[index] != 0xFF {
                    index += 1
                    continue
                }
                while index < count && base[index] == 0xFF {
                    index += 1
                }
                guard index < count else { return false }
                let marker = base[index]
                index += 1
                if marker == 0xD9 { return true }
                if marker == 0x00 || marker == 0x01 || marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) {
                    continue
                }
                guard index + 1 < count else { return false }
                let segmentLength = (Int(base[index]) << 8) | Int(base[index + 1])
                guard segmentLength >= 2, segmentLength <= count - index else { return false }
                index += segmentLength
                if marker == 0xDA {
                    while index + 1 < count {
                        if base[index] == 0xFF {
                            let next = base[index + 1]
                            if next == 0x00 || (next >= 0xD0 && next <= 0xD7) {
                                index += 2
                                continue
                            }
                            if next == 0xFF {
                                index += 1
                                continue
                            }
                            break
                        }
                        index += 1
                    }
                }
            }
            return false
        }
    }

    private static func hasCompletePNGStream(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let count = raw.count
            guard count >= 8,
                  base[0] == 0x89, base[1] == 0x50, base[2] == 0x4E, base[3] == 0x47,
                  base[4] == 0x0D, base[5] == 0x0A, base[6] == 0x1A, base[7] == 0x0A else {
                return false
            }
            var index = 8
            while index <= count - 12 {
                let length = (Int(base[index]) << 24)
                    | (Int(base[index + 1]) << 16)
                    | (Int(base[index + 2]) << 8)
                    | Int(base[index + 3])
                guard length >= 0, length <= count - index - 12 else { return false }
                let isIEND = base[index + 4] == 0x49
                    && base[index + 5] == 0x45
                    && base[index + 6] == 0x4E
                    && base[index + 7] == 0x44
                if isIEND { return length == 0 }
                index += 12 + length
            }
            return false
        }
    }

    static func decode(url: URL) -> Result<WallpaperDecodedImage, WallpaperImageDecodeFailure> {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        return autoreleasepool {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
                return .failure(.init(stage: "open", detail: url.lastPathComponent))
            }
            let type = CGImageSourceGetType(source) as String?
            if let failure = verifyContainerIntegrity(url: url, typeIdentifier: type) {
                return .failure(failure)
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
            let type = CGImageSourceGetType(source) as String?
            if !hasCompleteContainerStream(data, typeIdentifier: type) {
                return .failure(.init(stage: "integrity", detail: "truncated \(type ?? "image")"))
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
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // EXIF 5...8 transpose the axes. Preserve source pixels without another
        // decode; the thumbnail below applies the matching orientation transform.
        let swapsAxes = (5...8).contains(orientation)
        let sourceSize = CGSize(width: swapsAxes ? height.doubleValue : width.doubleValue,
                                height: swapsAxes ? width.doubleValue : height.doubleValue)
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
                return .success(WallpaperDecodedImage(image: image, sourceSize: sourceSize, attempts: attempt))
            }
            switch result {
            case .success: return result
            case .failure(let failure): lastFailure = failure
            }
        }
        return .failure(lastFailure)
    }
}
