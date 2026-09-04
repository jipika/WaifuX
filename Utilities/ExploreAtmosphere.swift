import SwiftUI
import AppKit
import Kingfisher
import Combine
import ImageIO

// MARK: - GIF Image Helpers

@MainActor
func configureAnimatedGIFViewForAspectFill(_ view: AnimatedImageView, autoPlay: Bool) {
    #if os(macOS)
    view.imageScaling = .scaleProportionallyUpOrDown
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.layer?.contentsGravity = .resizeAspectFill
    #elseif canImport(UIKit)
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    #endif
    view.autoPlayAnimatedImage = autoPlay
    view.needsPrescaling = true
    view.framePreloadCount = 1
}

actor AnimatedImageProbeCache {
    static let shared = AnimatedImageProbeCache()

    /// 内存缓存：使用 NSCache（线程安全）以便提供 nonisolated 同步读取接口。
    /// 这样 SwiftUI body 在同步求值期间就能命中缓存，避免每次卡片 mount 都启动一次
    /// async probe + setState 抖动（结果即使一致也会触发一次 body 重算）。
    /// `nonisolated(unsafe)`：NSCache 文档承诺所有访问皆线程安全，无需额外加锁。
    private nonisolated(unsafe) static let memoryCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    /// 最大并发探测数（避免快速滚动时大量并发 HTTP Range 请求）
    private let maxConcurrentProbes = 6
    private var activeProbes = 0
    private struct ProbeWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waitingProbes: [ProbeWaiter] = []

    private static let gifSignature = Data("GIF".utf8)
    private static let headerByteCount = 64 * 1024
    private static let defaultMaxPixelCount = 8_000_000
    private static let defaultMaxFrameCount = 180

    private nonisolated static func cacheKey(
        url: URL,
        maxByteCount: Int64,
        maxPixelCount: Int,
        maxFrameCount: Int
    ) -> NSString {
        "\(url.absoluteString)|b:\(maxByteCount)|p:\(maxPixelCount)|f:\(maxFrameCount)" as NSString
    }

    /// **同步**查询缓存（不发起任何探测）。SwiftUI body 可直接调用以避免异步抖动。
    /// 返回值：
    /// - `true`  → 已缓存为 GIF；
    /// - `false` → 已缓存为非 GIF；
    /// - `nil`   → 未探测过，调用方需要走 `isAnimatedGIF(...)` 异步流程。
    nonisolated func cachedIsAnimatedGIF(
        _ url: URL,
        maxByteCount: Int64,
        maxPixelCount: Int = defaultMaxPixelCount,
        maxFrameCount: Int = defaultMaxFrameCount
    ) -> Bool? {
        let key = Self.cacheKey(
            url: url,
            maxByteCount: maxByteCount,
            maxPixelCount: maxPixelCount,
            maxFrameCount: maxFrameCount
        )
        return Self.memoryCache.object(forKey: key)?.boolValue
    }

    /// 不看文件名/后缀，只读取实际图片响应/文件数据判断是否为可安全播放的 GIF。
    func isAnimatedGIF(
        _ url: URL,
        maxByteCount: Int64,
        maxPixelCount: Int = defaultMaxPixelCount,
        maxFrameCount: Int = defaultMaxFrameCount
    ) async -> Bool {
        let key = Self.cacheKey(
            url: url,
            maxByteCount: maxByteCount,
            maxPixelCount: maxPixelCount,
            maxFrameCount: maxFrameCount
        )
        if let cached = Self.memoryCache.object(forKey: key)?.boolValue {
            return cached
        }

        // 并发限制：等待槽位。hover 离开后要能移除排队中的探测，
        // 否则快速掠过网格会把已取消的 Range 请求继续排到后台执行。
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler(operation: {
            await acquireProbeSlot(id: waiterID)
        }, onCancel: {
            Task { await self.cancelProbeWaiter(id: waiterID) }
        })
        guard acquired else { return false }
        guard !Task.isCancelled else {
            releaseProbeSlot()
            return false
        }

        let result: Bool
        defer { releaseProbeSlot() }
        if url.isFileURL {
            result = Self.probeLocalGIF(
                url,
                maxByteCount: maxByteCount,
                maxPixelCount: maxPixelCount,
                maxFrameCount: maxFrameCount
            )
        } else {
            result = await Self.probeRemoteGIF(
                url,
                maxByteCount: maxByteCount,
                maxPixelCount: maxPixelCount,
                maxFrameCount: maxFrameCount
            )
        }

        // 取消不是“确认静态图”。快速移开鼠标时不能把取消结果写进负缓存，
        // 否则下一次 hover 会直接跳过真正的 GIF 探测。
        guard !Task.isCancelled else { return false }
        Self.memoryCache.setObject(NSNumber(value: result), forKey: key)
        return result
    }

    /// 等待一个并发槽位
    private func acquireProbeSlot(id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeProbes < maxConcurrentProbes {
            activeProbes += 1
            return true
        } else {
            return await withCheckedContinuation { continuation in
                waitingProbes.append(
                    ProbeWaiter(id: id, continuation: continuation)
                )
            }
        }
    }

    private func cancelProbeWaiter(id: UUID) {
        guard let index = waitingProbes.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waitingProbes.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// 释放并发槽位，唤醒等待者
    private func releaseProbeSlot() {
        if !waitingProbes.isEmpty {
            let next = waitingProbes.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            activeProbes -= 1
        }
    }

    private static func probeLocalGIF(
        _ url: URL,
        maxByteCount: Int64,
        maxPixelCount: Int,
        maxFrameCount: Int
    ) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value <= maxByteCount,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              dataLooksLikeGIF(data) else {
            return false
        }

        return imagePropertiesWithinBudget(
            data,
            maxPixelCount: maxPixelCount,
            maxFrameCount: maxFrameCount,
            requireAnimatedFrameCount: true
        )
    }

    private static func probeRemoteGIF(
        _ url: URL,
        maxByteCount: Int64,
        maxPixelCount: Int,
        maxFrameCount: Int
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("bytes=0-\(headerByteCount - 1)", forHTTPHeaderField: "Range")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        // 只接受 GIF，阻止 CDN 转换为 WebP 等格式
        request.setValue("image/gif,*/*;q=0.1", forHTTPHeaderField: "Accept")
        if let host = url.host?.lowercased() {
            if host.contains("steam") || host.contains("akamaihd") {
                request.setValue("https://steamcommunity.com/", forHTTPHeaderField: "Referer")
            } else if host.contains("motionbgs.com") {
                request.setValue("https://motionbgs.com/", forHTTPHeaderField: "Referer")
            } else if host.contains("wallhaven.cc") {
                request.setValue("https://wallhaven.cc/", forHTTPHeaderField: "Referer")
            }
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !data.isEmpty else {
            return false
        }
        if Int64(data.count) > maxByteCount {
            return false
        }
        if let byteCount = estimatedByteCount(from: response), byteCount > maxByteCount {
            return false
        }

        let mimeType = response.mimeType?.lowercased() ?? ""
        let looksLikeGIF = mimeType.contains("gif") || dataLooksLikeGIF(data)
        guard looksLikeGIF else { return false }

        // Range 响应通常只包含 GIF 开头的几十 KB。此时 ImageIO 只能看到首帧，
        // 不能据此判定它是单帧图；否则大 GIF 会被稳定误判为不可播放。
        // 完整响应仍可做帧数检查，部分响应只验证 GIF 头和画布尺寸。
        if let totalByteCount = estimatedByteCount(from: response),
           totalByteCount == Int64(data.count) {
            return imagePropertiesWithinBudget(
                data,
                maxPixelCount: maxPixelCount,
                maxFrameCount: maxFrameCount,
                requireAnimatedFrameCount: true
            )
        }
        return gifHeaderDimensionsWithinBudget(data, maxPixelCount: maxPixelCount)
    }

    private static func dataLooksLikeGIF(_ data: Data) -> Bool {
        data.starts(with: gifSignature)
    }

    private static func gifHeaderDimensionsWithinBudget(_ data: Data, maxPixelCount: Int) -> Bool {
        guard data.count >= 10, dataLooksLikeGIF(data) else { return false }
        let bytes = [UInt8](data.prefix(10))
        let width = Int(bytes[6]) | (Int(bytes[7]) << 8)
        let height = Int(bytes[8]) | (Int(bytes[9]) << 8)
        let pixels = width * height
        return pixels > 0 && pixels <= maxPixelCount
    }

    private static func imagePropertiesWithinBudget(
        _ data: Data,
        maxPixelCount: Int,
        maxFrameCount: Int,
        requireAnimatedFrameCount: Bool
    ) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }

        let frameCount = CGImageSourceGetCount(source)
        if requireAnimatedFrameCount, frameCount <= 1 {
            return false
        }
        if frameCount > maxFrameCount {
            return false
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return false
        }

        let pixels = width.intValue * height.intValue
        return pixels > 0 && pixels <= maxPixelCount
    }

    private static func estimatedByteCount(from response: URLResponse) -> Int64? {
        guard let http = response as? HTTPURLResponse else {
            return response.expectedContentLength > 0 ? response.expectedContentLength : nil
        }

        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let totalText = contentRange.split(separator: "/").last,
           let total = Int64(totalText) {
            return total
        }

        guard http.statusCode != 206 else { return nil }

        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        if let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(contentLength) {
            return total
        }
        return nil
    }

    private func store(_ result: Bool, for key: String) -> Bool {
        // 已迁移到 NSCache 直接写入。保留这个方法签名以防其他调用方，但内部直接缓存。
        Self.memoryCache.setObject(NSNumber(value: result), forKey: key as NSString)
        return result
    }
}

// MARK: - 探索页氛围色（背景光斑 + 液态玻璃主题色）

struct ExploreAtmosphereTint {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var baseTop: Color
    var baseBottom: Color

    static let wallpaperFallback = ExploreAtmosphereTint(
        primary: Color(hex: "5A7CFF"),
        secondary: Color(hex: "8A5CFF"),
        tertiary: Color(hex: "20C1FF"),
        baseTop: Color(hex: "1D2128"),
        baseBottom: Color(hex: "0E1116")
    )

    static let mediaFallback = ExploreAtmosphereTint(
        primary: Color(hex: "20C1FF"),
        secondary: Color(hex: "6D42FF"),
        tertiary: Color(hex: "2EE6A6"),
        baseTop: Color(hex: "1D2128"),
        baseBottom: Color(hex: "0E1116")
    )

    static func fromWallpaperMetadata(_ wallpaper: Wallpaper) -> ExploreAtmosphereTint {
        let palette = HeroDrivenPalette(wallpaper: wallpaper)
        return ExploreAtmosphereTint(
            primary: palette.primary,
            secondary: palette.secondary,
            tertiary: palette.tertiary,
            baseTop: Color(hex: "1D2128"),
            baseBottom: Color(hex: "0E1116")
        )
    }

    static func fromSampledTriplet(_ a: Color, _ b: Color, _ c: Color) -> ExploreAtmosphereTint {
        ExploreAtmosphereTint(
            primary: a,
            secondary: b,
            tertiary: c,
            baseTop: Color(hex: "1D2128"),
            baseBottom: Color(hex: "0E1116")
        )
    }
}

// MARK: - Environment（子视图同步主题色）

private struct ExplorePageAtmosphereTintKey: EnvironmentKey {
    static let defaultValue = ExploreAtmosphereTint.wallpaperFallback
}

extension EnvironmentValues {
    var explorePageAtmosphereTint: ExploreAtmosphereTint {
        get { self[ExplorePageAtmosphereTintKey.self] }
        set { self[ExplorePageAtmosphereTintKey.self] = newValue }
    }
}

// MARK: - Tab 后台时停列表 GIF（keep-alive 下 opacity=0 仍可能解码动画）

private struct CoverGIFPlaybackHostActiveKey: EnvironmentKey {
    /// 主窗口里当前 Tab 是否为该子树所属页（false 时 `KFMediaCoverImage` 强制不播 GIF）
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    /// 由 `ContentView` 按 `selectedTab` 注入；弹窗/详情未设置时默认为 `true`。
    var coverGIFPlaybackHostActive: Bool {
        get { self[CoverGIFPlaybackHostActiveKey.self] }
        set { self[CoverGIFPlaybackHostActiveKey.self] = newValue }
    }
}

// MARK: - 缩略图三色采样（左/中/右条带平均）

enum ExploreImageColorSampler {
    /// 从图片采样三色
    /// - Parameter image: 要采样的图片
    static func triplet(from image: NSImage) -> (Color, Color, Color)? {
        let pixelWidth: CGFloat = 48
        let pixelHeight: CGFloat = 48
        let size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelWidth),
            pixelsHigh: Int(pixelHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()

        let drawRect = NSRect(origin: .zero, size: size)
        let sourceRect: NSRect = .zero

        image.draw(
            in: drawRect,
            from: sourceRect,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpp = max(rep.bitsPerPixel / 8, 4)

        func average(in rect: (x: Int, y: Int, width: Int, height: Int)) -> (Double, Double, Double) {
            var r: Double = 0
            var g: Double = 0
            var b: Double = 0
            var n: Double = 0
            let x1 = max(0, rect.x)
            let y1 = max(0, rect.y)
            let x2 = min(w, rect.x + rect.width)
            let y2 = min(h, rect.y + rect.height)
            for y in y1..<y2 {
                for x in x1..<x2 {
                    let o = (y * w + x) * bpp
                    guard o + 2 < rep.bytesPerRow * h else { continue }
                    r += Double(data[o])
                    g += Double(data[o &+ 1])
                    b += Double(data[o &+ 2])
                    n += 1
                }
            }
            guard n > 0 else { return (0.15, 0.15, 0.18) }
            return (r / n / 255, g / n / 255, b / n / 255)
        }

        let colW = max(1, w / 3)
        let a1 = boost(average(in: (0, 0, colW, h)))
        let a2 = boost(average(in: (colW, 0, colW, h)))
        let a3 = boost(average(in: (colW * 2, 0, w - colW * 2, h)))

        return (color(from: a1), color(from: a2), color(from: a3))
    }

    private static func boost(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let mx = max(rgb.0, rgb.1, rgb.2)
        let mn = min(rgb.0, rgb.1, rgb.2)
        let saturation = mx > 0 ? (mx - mn) / mx : 0

        // 基础提亮：让整体更亮更通透
        let brighten: (Double) -> Double = { c in
            // 非线性提亮：暗部提升更多，亮部保持
            let lifted = pow(c, 0.85)
            // 整体提亮 15%
            return min(1.0, lifted * 1.15 + 0.04)
        }

        var r = brighten(rgb.0)
        var g = brighten(rgb.1)
        var b = brighten(rgb.2)

        // 低饱和度颜色（偏灰）：增加一点冷暖倾向，避免死灰
        if saturation < 0.12 {
            if mx == rgb.0 { r = min(1, r + 0.08) }
            else if mx == rgb.2 { b = min(1, b + 0.08) }
            else { g = min(1, g + 0.06); b = min(1, b + 0.04) }
        }

        // 增加饱和度：让颜色更鲜艳
        let avg = (r + g + b) / 3
        let satBoost: Double = saturation < 0.3 ? 1.25 : 1.1
        r = min(1, avg + (r - avg) * satBoost)
        g = min(1, avg + (g - avg) * satBoost)
        b = min(1, avg + (b - avg) * satBoost)

        return (r, g, b)
    }

    private static func color(from rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

// MARK: - 氛围底图用缩略 NSImage（降低全屏 blur 的像素与内存）

extension NSImage {
    /// 限制最大边长（点），供 `ExploreDynamicAtmosphereBackground` 做大面积模糊用，避免对原图全尺寸 blur。
    func constrainedForAtmosphereBackdrop(maxEdge: CGFloat = 512) -> NSImage {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return self }
        let longest = max(w, h)
        guard longest > maxEdge else { return self }
        let scale = maxEdge / longest
        let nw = max(1, floor(w * scale))
        let nh = max(1, floor(h * scale))
        let newSize = NSSize(width: nw, height: nh)
        let img = NSImage(size: newSize)
        img.lockFocus()
        defer { img.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .low
        draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: NSSize(width: w, height: h)),
            operation: .copy,
            fraction: 1
        )
        return img
    }
}

// MARK: - 控制器（首张卡片缩略图 + 采样）

@MainActor
final class ExploreAtmosphereController: ObservableObject {
    @Published private(set) var tint: ExploreAtmosphereTint {
        didSet { headerStyleVersion &+= 1 }
    }
    @Published private(set) var referenceImage: NSImage?
    @Published private(set) var headerStyleVersion: UInt = 0

    private var loadTask: Task<Void, Never>?
    private let wallpaperMode: Bool
    private let atmosphereSampleSize = CGSize(width: 512, height: 512)
    /// 避免列表刷新但首张未变时重复拉缩略图、重复采样
    private var activeFirstItemKey: String?
    private var cancellables = Set<AnyCancellable>()

    init(wallpaperMode: Bool) {
        self.wallpaperMode = wallpaperMode
        self.tint = wallpaperMode ? .wallpaperFallback : .mediaFallback

        // 监听应用隐藏窗口通知，清理大内存占用（异步执行避免卡顿）
        NotificationCenter.default.publisher(for: .appDidHideWindow)
            .sink { [weak self] _ in
                // 使用低优先级队列异步执行
                Task(priority: .background) { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒延迟
                    self?.clearMemory()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        loadTask?.cancel()
        // cancellables 会自动释放，无需手动清理
    }

    /// 清理大内存占用，但保留颜色主题
    func clearMemory() {
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil
        // 不重置 activeFirstItemKey，这样重新打开窗口时不会重复加载同一张图
    }

    func resetToFallback() {
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil
        activeFirstItemKey = nil
        tint = wallpaperMode ? .wallpaperFallback : .mediaFallback
    }

    /// 切到其他 tab 时暂停后台任务（保留当前颜色，只取消未完成的加载）
    func pause() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func retrieveAtmosphereImage(from url: URL) async -> KFCrossPlatformImage? {
        let processor = DownsamplingImageProcessor(size: atmosphereSampleSize)
        let result = try? await KingfisherManager.shared.retrieveImage(
            with: .network(url),
            options: [
                .processor(processor),
                .backgroundDecode
            ]
        )
        return result?.image
    }

    func updateFirstWallpaper(_ wallpaper: Wallpaper?) {
        guard let wallpaper else {
            resetToFallback()
            return
        }

        let key = "w:\(wallpaper.id)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key

        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = ExploreAtmosphereTint.fromWallpaperMetadata(wallpaper)

        guard let url = wallpaper.thumbURL ?? wallpaper.smallThumbURL else { return }

        loadTask = Task {
            guard let image = await retrieveAtmosphereImage(from: url),
                  !Task.isCancelled else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }

    func updateFirstMedia(_ item: MediaItem?) {
        guard let item else {
            resetToFallback()
            return
        }

        let key = "m:\(item.id)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key

        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = .mediaFallback
        // 列表首屏优先用缩略图做氛围采样，避免首次进入时解码较大的 poster 图造成卡顿。
        let url = item.thumbnailURL

        loadTask = Task {
            guard let image = await retrieveAtmosphereImage(from: url),
                  !Task.isCancelled else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }

    func updateFirstAnime(coverURL: String) {
        guard !coverURL.isEmpty else {
            resetToFallback()
            return
        }

        let key = "a:\(coverURL)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = .mediaFallback

        guard let url = URL(string: coverURL) else { return }

        loadTask = Task {
            guard let image = await retrieveAtmosphereImage(from: url),
                  !Task.isCancelled else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }

    /// 从任意图片 URL 更新氛围背景（用于随机切换，不持久化）
    func updateFromImageURL(_ url: URL?, keyPrefix: String = "rand") {
        guard let url else {
            resetToFallback()
            return
        }
        let key = "\(keyPrefix):\(url.absoluteString)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        loadTask = Task {
            guard let image = await retrieveAtmosphereImage(from: url),
                  !Task.isCancelled else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }
}

// MARK: - Arc 风格颗粒噪点纹理（更精细、更高对比度）

// MARK: - 全局胶片噪点纹理

/// 胶片颗粒纹理生成器（CIFilter 管线 + 簇化缩放）
///
/// 参考实现：neberej/daily-tools-mac-ios GrainEffect.swift
/// 关键技术：CIRandomGenerator 生成高频噪声 → 缩小 0.25x → 最近邻放大 4x
/// 产生 2~3 像素的颗粒簇（而非单像素数字噪点），模拟真实胶片的有机颗粒感
enum GrainTextureTile {
    /// 用于 SwiftUI `.blendMode(.softLight)` 的单帧颗粒纹理
    static let image: NSImage = generateGrainTile()

    /// 用于 NSView CGContext overlay 混合的单帧颗粒纹理
    static let cgImage: CGImage = generateGrainCGImage()

    // MARK: - 私有生成

    private static func generateGrainTile() -> NSImage {
        let ciImage = makeGrainCIImage()
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: NSSize(width: rep.size.width, height: rep.size.height))
        nsImage.addRepresentation(rep)
        return nsImage
    }

    private static func generateGrainCGImage() -> CGImage {
        let ciImage = makeGrainCIImage()
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let w = Int(ciImage.extent.width)
        let h = Int(ciImage.extent.height)
        let fallback = CIContext().createCGImage(
            CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)),
            from: CGRect(x: 0, y: 0, width: 256, height: 256)
        )!
        return context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: w, height: h))
            ?? fallback
    }

    private static func makeGrainCIImage() -> CIImage {
        // 1. CIRandomGenerator：生成全白高频噪声
        guard let noiseFilter = CIFilter(name: "CIRandomGenerator") else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        }
        var noise = noiseFilter.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))

        // 2. CIColorControls：去饱和 + 降低亮度 → 单色暗调噪点
        //    saturation=0 去色；brightness=-0.3 整体压暗，模拟胶片颗粒的暗调特征
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(noise, forKey: kCIInputImageKey)
            colorFilter.setValue(0.0, forKey: kCIInputSaturationKey)
            colorFilter.setValue(-0.3, forKey: kCIInputBrightnessKey)
            noise = colorFilter.outputImage ?? noise
        }

        // 3. 簇化缩放（关键技术）：
        //    缩小到 0.25x 丢失细节，再用最近邻放大 4x → 单像素变成 4x4 像素块
        //    产生 2~3 像素的颗粒簇，这是胶片颗粒与数字噪点的核心区别
        let clusterScale: CGFloat = 0.25
        let zoomed = noise
            .transformed(by: CGAffineTransform(scaleX: clusterScale, y: clusterScale))
            .transformed(by: CGAffineTransform(scaleX: 1.0 / clusterScale, y: 1.0 / clusterScale))

        // 4. 裁剪到 256x256 输出区域（放大后中心区域）
        let outputSize = 256.0
        let cropRect = CGRect(
            x: zoomed.extent.midX - outputSize / 2,
            y: zoomed.extent.midY - outputSize / 2,
            width: outputSize,
            height: outputSize
        )
        return zoomed.cropped(to: cropRect)
    }
}

// MARK: - 动态背景：散色模糊底图 + 原有氛围渐变 + 轻磨砂 + 噪点

struct ExploreDynamicAtmosphereBackground: View {
    let tint: ExploreAtmosphereTint
    let referenceImage: NSImage?
    /// 快速滚动时减轻效果，避免卡顿
    var lightweightBackdrop: Bool = false

    // 预计算颜色值（避免 body 中重复创建 Color 结构体）
    private var primaryColor: Color { tint.primary }
    private var secondaryColor: Color { tint.secondary }
    private var tertiaryColor: Color { tint.tertiary }
    private var baseTopColor: Color { tint.baseTop }

    var body: some View {
        ZStack {
            // 基础氛围背景
            LiquidGlassAtmosphereBackground(
                primary: primaryColor,
                secondary: secondaryColor,
                tertiary: tertiaryColor,
                baseTop: baseTopColor,
                baseBottom: tint.baseBottom
            )

            // 参考图片模糊背景（轻量模式时完全禁用）
            if !lightweightBackdrop, let referenceImage {
                // 参考图已在控制器中压到最长边约 256pt，此处用适中 blur 即可铺满视觉，避免对大图做超大半径模糊
                Image(nsImage: referenceImage)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 160, minHeight: 160)
                    .blur(radius: 32)
                    .opacity(0.2)
                    .saturation(1.05)
                    .allowsHitTesting(false)
            }

            // 漫射光晕：分散到四个角落，避免只集中在中间
            RadialGradient(
                colors: [
                    primaryColor.opacity(lightweightBackdrop ? 0.10 : 0.14),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: lightweightBackdrop ? 400 : 600
            )
            .allowsHitTesting(false)

            RadialGradient(
                colors: [
                    secondaryColor.opacity(lightweightBackdrop ? 0.08 : 0.12),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: lightweightBackdrop ? 350 : 550
            )
            .allowsHitTesting(false)

            RadialGradient(
                colors: [
                    tertiaryColor.opacity(lightweightBackdrop ? 0.06 : 0.10),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: lightweightBackdrop ? 300 : 450
            )
            .allowsHitTesting(false)

            // 极淡的中心提亮，平衡四角
            RadialGradient(
                colors: [
                    baseTopColor.opacity(0.04),
                    Color.clear
                ],
                center: .center,
                startRadius: 100,
                endRadius: lightweightBackdrop ? 500 : 700
            )
            .allowsHitTesting(false)

            // 底部极淡过渡（仅轻微压暗，避免底部过暗）
            LinearGradient(
                colors: [
                    Color.clear,
                    tint.baseBottom.opacity(0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

// MARK: - Kingfisher 列表降采样

extension KFImage {
    /// 列表/卡片传入 `cardSize * 2` 等，避免 GIF/大图按全分辨率在主线程解码。
    fileprivate func wh_optionalDownsample(_ size: CGSize?) -> KFImage {
        guard let size else { return self }
        return setProcessor(DownsamplingImageProcessor(size: size))
    }
}

extension KFAnimatedImage {
    fileprivate func wh_optionalDownsample(_ size: CGSize?) -> KFAnimatedImage {
        self
    }
}

// MARK: - 媒体封面（静态 / GIF统一加载 + 失败占位）

/// 列表/首页封面：底层始终有色块/渐变，避免加载失败时出现空白或系统错误图。
/// 统一使用 `KFAnimatedImage`：Kingfisher 内部会解析真实文件格式，
/// GIF 自动走动画管线，静态图则回退到普通 ImageView 行为，无需外部根据 URL 预判断。
struct KFMediaCoverImage: View {
    @Environment(\.coverGIFPlaybackHostActive) private var coverGIFPlaybackHostActive

    let url: URL
    var animated: Bool
    /// 非 nil 时对 **KFImage / KFAnimatedImage** 解码做降采样（列表/卡片必传，显著减轻 Workshop GIF 全尺寸主线程解码）。
    var downsampleSize: CGSize? = nil
    var fadeDuration: Double = 0.25
    /// 任意一次加载结束（成功或失败）时调用，用于详情页淡入等。
    var loadFinished: (() -> Void)? = nil
    /// 列表/卡片必须传入，约束 `KFAnimatedImage`（AppKit）按 GIF 原始尺寸撑开父布局的问题。
    var layoutSize: CGSize? = nil
    /// 是否允许播放 GIF 动画；详情页等大图建议 true。
    var playAnimatedImage: Bool = false
    /// 当前卡片/视图是否在视口内；非「仅悬停播放」模式下，离屏时停动画。
    var isVisible: Bool = true
    /// `true` 时仅在 `isHovered == true` 时解码播放 GIF（列表/网格推荐，显著减轻滚动时主线程压力）。
    var animateOnHoverOnly: Bool = false
    /// 配合 `animateOnHoverOnly`；由卡片 `onHover` / `throttledHover` 传入。
    var isHovered: Bool = false

    @State private var detectedGIF = false
    @State private var loadFailed = false

    private let maxAnimatedGIFBytes: Int64 = 18 * 1024 * 1024

    private var shouldShowStaticLayer: Bool {
        !detectedGIF || loadFailed
    }

    private var shouldAnimate: Bool {
        guard playAnimatedImage, coverGIFPlaybackHostActive else { return false }
        if animateOnHoverOnly {
            return isHovered
        }
        return isVisible
    }

    /// `KFAnimatedImage` 的 `configure` 在 SwiftUI 更新时不一定会同步到已有 NSView；仅悬停播放时让 `id` 随悬停变化以强制重建并应用 `autoPlayAnimatedImage`。
    private var kfAnimatedLayerIdentity: String {
        if animateOnHoverOnly {
            "\(url.absoluteString)|hover:\(isHovered)"
        } else {
            url.absoluteString
        }
    }

    private var underlay: some View {
        LinearGradient(
            colors: [
                Color(hex: "1C2431"),
                Color(hex: "233B5A"),
                Color(hex: "14181F")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        let core = ZStack {
            underlay
            // 静态层只负责非 GIF 或动画加载失败的封面；确认 GIF 后释放，避免静态图和动画层长期双持有。
            if shouldShowStaticLayer {
                KFImage(url)
                    .wh_optionalDownsample(downsampleSize)
                    .cacheMemoryOnly(false)
                    .cancelOnDisappear(true)
                    .fade(duration: fadeDuration)
                    .placeholder { _ in underlay }
                    .onSuccess { result in
                        if !detectedGIF, result.image.kf.gifRepresentation() != nil {
                            detectedGIF = true
                        }
                        loadFinished?()
                    }
                    .onFailure { _ in loadFinished?() }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }

            // 2. 若真实格式为 GIF 且允许动画，叠加 KFAnimatedImage 播放动效
            if detectedGIF && !loadFailed {
                KFAnimatedImage.url(url)
                    .memoryCacheExpiration(.expired)
                    .diskCacheExpiration(.days(3))
                    .cancelOnDisappear(true)
                    .configure { view in
                        configureAnimatedGIFViewForAspectFill(view, autoPlay: shouldAnimate)
                    }
                    .placeholder { _ in underlay }
                    .onSuccess { _ in loadFinished?() }
                    .onFailure { _ in
                        loadFailed = true
                        loadFinished?()
                    }
                    // 非「仅悬停」模式：仅用 URL 稳定身份。
                    // 「仅悬停」模式：`id` 必须随 `isHovered` 变化，否则 AppKit 侧不会响应 `autoPlayAnimatedImage` 切换。
                    .id(kfAnimatedLayerIdentity)
                    .aspectRatio(contentMode: .fill)
            }
        }

        Group {
            if let s = layoutSize {
                core.frame(width: s.width, height: s.height).clipped()
            } else {
                core
            }
        }
        .task(id: url.absoluteString) {
            detectedGIF = false
            loadFailed = false
            // 探针始终运行以检测真实内容是否为 GIF，不依赖 URL 后缀启发式。
            // animated 参数仅用于 shouldAnimate（控制动画播放），不影响检测逻辑。
            let result = await AnimatedImageProbeCache.shared.isAnimatedGIF(url, maxByteCount: maxAnimatedGIFBytes)
            guard !Task.isCancelled else { return }
            detectedGIF = result
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
            detectedGIF = false
            loadFailed = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidReceiveMemoryPressure)) { _ in
            detectedGIF = false
            loadFailed = false
        }
    }
}

/// 兼容旧调用点：等价于 `KFMediaCoverImage(url:animated:true)` 。
struct KingfisherGIFImage: View {
    let url: URL

    var body: some View {
        KFMediaCoverImage(
            url: url,
            animated: true,
            downsampleSize: nil,
            fadeDuration: 0.2,
            loadFinished: nil,
            layoutSize: nil,
            playAnimatedImage: true,
            isVisible: true,
            animateOnHoverOnly: false,
            isHovered: false
        )
    }
}

// MARK: - 预览窗口管理器
@MainActor
final class PreviewWindowManager: ObservableObject {
    static let shared = PreviewWindowManager()

    private var windowController: NSWindowController?
    private var closeObserver: NSObjectProtocol?
    @Published private(set) var isPresented = false

    private init() {}

    func closePreview() {
        guard isPresented else { return }
        removeCloseObserver()
        if let window = windowController?.window {
            // 主动断开 hosting view，确保 SwiftUI 视图树立即销毁
            // (PreviewPlayer @StateObject 走 deinit → AVPlayer 停播)
            window.contentView = nil
        }
        windowController?.close()
        windowController = nil
        isPresented = false
    }

    private func removeCloseObserver() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
    }

    func openPreview(url: URL, aspectRatio: Double? = nil, isWeb: Bool = false, posterURL: URL? = nil) {
        removeCloseObserver()
        windowController?.close()
        windowController = nil

        let screen = WindowSpaceCoordinator.referenceWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let maxWidth = max(1000, screenFrame.width * 0.85)
        let maxHeight = max(700, screenFrame.height * 0.85)

        var width = maxWidth
        var height = maxHeight

        // 根据图片实际比例计算窗口尺寸，竖图窗口也保持竖比例
        if let ratio = aspectRatio, ratio > 0 {
            let containerAspect = maxWidth / maxHeight
            if ratio > containerAspect {
                // 图片比容器更宽：宽度撑满，高度按比例
                width = maxWidth
                height = maxWidth / ratio
            } else {
                // 图片比容器更高（含竖图）：高度撑满，宽度按比例
                height = maxHeight
                width = maxHeight * ratio
            }
        }

        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2

        let window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "预览"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 400)
        WindowSpaceCoordinator.prepare(window)

        let hostingView = NSHostingView(
            rootView: WallpaperPreviewSheet(url: url, isWeb: isWeb, posterURL: posterURL)
        )
        window.contentView = hostingView

        windowController = NSWindowController(window: window)
        windowController?.showWindow(nil)
        WindowSpaceCoordinator.show(window)
        isPresented = true

        // 监听窗口关闭（用户点击关闭按钮时同步状态）
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeCloseObserver()
                // 主动断开 hosting view，触发 SwiftUI .onDisappear /
                // PreviewPlayer.deinit，避免 AVPlayer 在窗口隐藏后继续播放音频
                if let win = self.windowController?.window {
                    win.contentView = nil
                }
                self.windowController = nil
                self.isPresented = false
            }
        }
    }
}
