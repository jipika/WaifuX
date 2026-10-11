//  BMP 快照缓存 — 消除灰色过渡。
//
//  WallpaperExtensionKit 的内置 VideoPlayer 会自动写入 BMP 缓存文件，
//  但由于我们使用原始 AVSampleBufferDisplayLayer，跳过了它的缓存机制。
//  没有此缓存，每次切换壁纸时桌面会显示 ~1 分钟的灰色，直到扩展启动。
//
//  格式与 Apple 自己的缓存文件一致：BITMAPINFOHEADER, 24bpp BGR, top-down。
//  cacheDirectory URL 是安全作用域资源（通过 XPC 从 WallpaperAgent 传入）。
//
//  参考 Phosphene (MIT) 的实现。

@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// 从 Agent 的缓存目录加载最新的 BMP 作为 CGImage。
/// 用于在过渡期间设置 rootLayer.contents 作为即时视觉内容，
/// 匹配 Apple 的"使用现有快照作为初始壁纸内容"模式。
func loadCachedSnapshotImage() -> CGImage? {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else { return nil }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else {
        return nil
    }

    // 优先匹配当前 videoID 的 BMP
    let currentVideoID = WallpaperState.shared.currentVideoID
    let bmpFiles = contents.filter { $0.pathExtension == "bmp" }

    let bmpURL: URL?
    if let videoID = currentVideoID {
        let hash = videoHash(for: videoID)
        bmpURL = bmpFiles.first { $0.lastPathComponent.hasPrefix(hash) } ?? bmpFiles.first
    } else {
        bmpURL = bmpFiles.first
    }

    guard let url = bmpURL else { return nil }

    guard let cgImage = loadBudgetedSnapshotImage(url) else {
        extLog("  [InitContent] 解码缓存 BMP 失败: \(url.lastPathComponent)")
        return nil
    }

    extLog("  [InitContent] 已加载缓存快照: \(url.lastPathComponent) (\(cgImage.width)x\(cgImage.height))")
    return cgImage
}

/// 将视频的第一帧以 BMP 格式写入 Agent 的缓存目录。
/// 每个视频有自己的 BMP 文件（通过 videoID hash 键控），
/// 确保 Agent 在视频之间切换时显示正确的缓存帧。
private struct BMPSnapshotRequest: Equatable, Sendable {
    let displayID: UInt32
    let videoURL: URL
    let videoID: String?
    let displayPixelWidth: Int
    let displayPixelHeight: Int
    let cacheDirectory: URL
}

private let bmpSnapshotWork = LatestWallpaperSnapshotWork<BMPSnapshotRequest, Bool>(maximumReplies: 0, maximumKeys: 16,
                                                                                 key: { $0.displayID }, cacheIf: { $0 },
                                                                                 cacheLifetime: { _ in 60 }) { request in
    await wallpaperSnapshotDecodeGate.perform { await writeBMPSnapshot(request) }
}

func requestBMPSnapshot(videoURL: URL, videoID: String? = nil, displayID: UInt32, displayPixelWidth: Int, displayPixelHeight: Int) {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL,
          displayPixelWidth > 0, displayPixelHeight > 0 else { return }
    bmpSnapshotWork.submit(BMPSnapshotRequest(displayID: displayID, videoURL: videoURL, videoID: videoID,
                                            displayPixelWidth: displayPixelWidth, displayPixelHeight: displayPixelHeight,
                                            cacheDirectory: cacheDir))
}

private func writeBMPSnapshot(_ request: BMPSnapshotRequest) async -> Bool {
    guard !Task.isCancelled else { return false }
    let videoURL = request.videoURL
    let videoID = request.videoID
    let displayPixelWidth = request.displayPixelWidth
    let displayPixelHeight = request.displayPixelHeight
    let cacheDir = request.cacheDirectory
    guard WallpaperState.shared.cacheDirectoryURL == cacheDir else {
        extLog("  [BMPCache] 无 cacheDirectoryURL，跳过")
        return false
    }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard gained else {
        extLog("  [BMPCache] 无法获取安全作用域资源访问")
        return false
    }

    let hashHex = videoHash(for: videoID ?? videoURL.lastPathComponent)

    // A display's instance ID can survive a video switch. Matching the existing
    // filename/size cannot establish that its contents come from this video.
    // The coordinator deduplicates the complete request instead.
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    if #available(macOS 15.0, *) { generator.dynamicRangePolicy = .forceSDR }
    generator.maximumSize = CGSize(width: WallpaperSnapshotPixelBudget.maximumVideoImageDimension,
                                   height: WallpaperSnapshotPixelBudget.maximumVideoImageDimension)

    let cgImage: CGImage
    do {
        cgImage = try await withTaskCancellationHandler(operation: {
            try await generator.image(at: .zero).image
        }, onCancel: { generator.cancelAllCGImageGeneration() })
    } catch {
        extLog("  [BMPCache] 获取视频帧失败: \(error)")
        return false
    }

    guard !Task.isCancelled,
          WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: cgImage.width, height: cgImage.height, bytesPerRow: cgImage.bytesPerRow),
          let layout = WallpaperSnapshotPixelBudget.layout(width: Double(cgImage.width), height: Double(cgImage.height)) else { return false }

    let width = layout.width
    let height = layout.height
    let bytesPerPixel = 3 // 24bpp BGR
    let rawRowBytes = width * bytesPerPixel
    let paddedRowBytes = (rawRowBytes + 3) & ~3
    let pixelDataSize = paddedRowBytes * height

    extLog("  [BMPCache] 渲染 \(width)x\(height) BGR24 (\(pixelDataSize) 字节, row=\(paddedRowBytes))")

    let bgraRowBytes = width * 4
    var bgraData = Data(count: bgraRowBytes * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    let rendered = bgraData.withUnsafeMutableBytes { rawBuf -> Bool in
        guard let ctx = CGContext(
            data: rawBuf.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bgraRowBytes,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    guard rendered else {
        extLog("  [BMPCache] CGContext 渲染失败")
        return false
    }

    // 转换 BGRA → BGR24 并添加行填充
    let fileHeaderSize = 14
    let dibHeaderSize = 40
    let headerSize = fileHeaderSize + dibHeaderSize
    let fileSize = headerSize + pixelDataSize
    var bmp = Data(count: fileSize)
    bgraData.withUnsafeBytes { bgra in
        bmp.withUnsafeMutableBytes { bgr in
            let src = bgra.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let dst = bgr.baseAddress!.advanced(by: headerSize).assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let si = y * bgraRowBytes + x * 4
                    let di = y * paddedRowBytes + x * 3
                    dst[di] = src[si]     // B
                    dst[di + 1] = src[si + 1] // G
                    dst[di + 2] = src[si + 2] // R
                }
            }
        }
    }

    // 构建 BMP: 14 字节文件头 + 40 字节 BITMAPINFOHEADER + 像素数据
    bmp[0] = 0x42; bmp[1] = 0x4D // "BM"
    bmpWriteLE32(&bmp, offset: 2, value: UInt32(fileSize))
    bmpWriteLE32(&bmp, offset: 10, value: UInt32(headerSize))

    let d = fileHeaderSize
    bmpWriteLE32(&bmp, offset: d, value: UInt32(dibHeaderSize))
    bmpWriteLE32(&bmp, offset: d + 4, value: UInt32(bitPattern: Int32(width)))
    bmpWriteLE32(&bmp, offset: d + 8, value: UInt32(bitPattern: Int32(-height))) // top-down
    bmpWriteLE16(&bmp, offset: d + 12, value: 1) // planes
    bmpWriteLE16(&bmp, offset: d + 14, value: 24) // bits per pixel
    bmpWriteLE32(&bmp, offset: d + 16, value: 0) // BI_RGB
    bmpWriteLE32(&bmp, offset: d + 20, value: UInt32(pixelDataSize))

    bgraData = Data()
    guard !Task.isCancelled, WallpaperState.shared.cacheDirectoryURL == cacheDir else { return false }

    let timestamp = Date().timeIntervalSinceReferenceDate
    let timestampHex = String(format: "%016llx", timestamp.bitPattern)
    let filename = "\(hashHex)-\(displayPixelWidth)-\(displayPixelHeight)-0-\(timestampHex).bmp"

    let bmpURL = cacheDir.appendingPathComponent(filename)
    do {
        guard !Task.isCancelled else { return false }
        try bmp.write(to: bmpURL, options: .atomic)
        extLog("  [BMPCache] 已写入 \(bmp.count) 字节 → \(filename)")
    } catch {
        extLog("  [BMPCache] 写入失败: \(error)")
        return false
    }

    // Preserve the previous fallback until the replacement is fully written.
    // A cancelled decode must not remove the last usable snapshot.
    guard !Task.isCancelled, WallpaperState.shared.cacheDirectoryURL == cacheDir else { return false }
    // Two displays may use the same video ID at different native resolutions.
    // Keep the other resolution's cache. Equal ID/resolution can share a BMP.
    let matchingCachePrefix = "\(hashHex)-\(displayPixelWidth)-\(displayPixelHeight)-"
    if let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
        for file in contents where file != bmpURL && file.pathExtension == "bmp" && file.lastPathComponent.hasPrefix(matchingCachePrefix) {
            guard !Task.isCancelled else { return false }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // 写入 cacheVersion.db
    let versionURL = cacheDir.appendingPathComponent("cacheVersion.db")
    do {
        try Data("{\"version\":2}".utf8).write(to: versionURL, options: .atomic)
    } catch {
        extLog("  [BMPCache] cacheVersion.db 失败: \(error)")
    }
    return true
}

/// 为视频标识符生成一致的 hash 前缀。
private func videoHash(for identifier: String) -> String {
    let hash = SHA256.hash(data: Data(identifier.utf8))
    return hash.compactMap { String(format: "%02x", $0) }.joined()
}

// MARK: - BMP 二进制写入辅助

private func bmpWriteLE16(_ data: inout Data, offset: Int, value: UInt16) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
}

private func bmpWriteLE32(_ data: inout Data, offset: Int, value: UInt32) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
    data[offset + 2] = UInt8((value >> 16) & 0xFF)
    data[offset + 3] = UInt8((value >> 24) & 0xFF)
}
