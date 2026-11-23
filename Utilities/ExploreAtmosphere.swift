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
    /// 可播放 GIF 的统一预算：详情 / 网格 / 库卡片共用同一组值。
    /// probe 缓存 key 含这三个参数，调用点错开任何一项都会互不命中、重复探测；
    /// 曾出现详情 18MB/8Mpx/180 帧 vs 网格 32MB/32Mpx/∞ 帧的分裂：
    /// 同一张大 GIF「网格 hover 会动、详情永远不动」。
    /// 帧数上限只约束本地/完整响应（ImageIO 全量解析的解码内存保护）；
    /// 远程 Range 部分响应只验 GIF 头 + 画布像素，不受帧数限制。
    static let defaultMaxAnimatedGIFBytes: Int64 = 32 * 1024 * 1024
    static let defaultMaxPixelCount = 32_000_000
    static let defaultMaxFrameCount = Int.max

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
        maxByteCount: Int64 = defaultMaxAnimatedGIFBytes,
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

    /// 丢弃某 URL 的既有探测结论（详情页「重试」用）：
    /// 覆盖「CDN 曾以 200 返回错误格式」这类被确定性负缓存记死的情况。
    nonisolated func invalidate(
        _ url: URL,
        maxByteCount: Int64 = defaultMaxAnimatedGIFBytes,
        maxPixelCount: Int = defaultMaxPixelCount,
        maxFrameCount: Int = defaultMaxFrameCount
    ) {
        let key = Self.cacheKey(
            url: url,
            maxByteCount: maxByteCount,
            maxPixelCount: maxPixelCount,
            maxFrameCount: maxFrameCount
        )
        Self.memoryCache.removeObject(forKey: key)
    }

    /// 探测结论。网络/IO 瞬态失败与「确认不是 GIF」必须分开：
    /// 失败结果不得写入负缓存，否则代理抖一次就把该 URL 整个进程生命周期判死。
    enum ProbeOutcome: Equatable {
        /// 已确认是可播放 GIF（可缓存）
        case animatedGIF
        /// 已确认不是 GIF / 超预算（可缓存）
        case notAnimated
        /// 网络/IO 失败或任务取消：结论未知，不缓存，下次访问重试
        case inconclusive
    }

    /// 不看文件名/后缀，只读取实际图片响应/文件数据判断是否为可安全播放的 GIF。
    func isAnimatedGIF(
        _ url: URL,
        maxByteCount: Int64 = defaultMaxAnimatedGIFBytes,
        maxPixelCount: Int = defaultMaxPixelCount,
        maxFrameCount: Int = defaultMaxFrameCount
    ) async -> Bool {
        await probeOutcome(
            url,
            maxByteCount: maxByteCount,
            maxPixelCount: maxPixelCount,
            maxFrameCount: maxFrameCount
        ) == .animatedGIF
    }

    /// 三态探测入口：只有确定性结论（是/否）写缓存；瞬态失败返回 `.inconclusive` 且不落缓存。
    func probeOutcome(
        _ url: URL,
        maxByteCount: Int64 = defaultMaxAnimatedGIFBytes,
        maxPixelCount: Int = defaultMaxPixelCount,
        maxFrameCount: Int = defaultMaxFrameCount
    ) async -> ProbeOutcome {
        let key = Self.cacheKey(
            url: url,
            maxByteCount: maxByteCount,
            maxPixelCount: maxPixelCount,
            maxFrameCount: maxFrameCount
        )
        if let cached = Self.memoryCache.object(forKey: key)?.boolValue {
            return cached ? .animatedGIF : .notAnimated
        }

        // 并发限制：等待槽位。hover 离开后要能移除排队中的探测，
        // 否则快速掠过网格会把已取消的 Range 请求继续排到后台执行。
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler(operation: {
            await acquireProbeSlot(id: waiterID)
        }, onCancel: {
            Task { await self.cancelProbeWaiter(id: waiterID) }
        })
        guard acquired else { return .inconclusive }
        guard !Task.isCancelled else {
            releaseProbeSlot()
            return .inconclusive
        }

        let outcome: ProbeOutcome
        defer { releaseProbeSlot() }
        if url.isFileURL {
            outcome = Self.probeLocalGIF(
                url,
                maxByteCount: maxByteCount,
                maxPixelCount: maxPixelCount,
                maxFrameCount: maxFrameCount
            )
        } else {
            outcome = await Self.probeRemoteGIF(
                url,
                maxByteCount: maxByteCount,
                maxPixelCount: maxPixelCount,
                maxFrameCount: maxFrameCount
            )
        }

        // 取消/瞬态失败不是“确认静态图”。快速移开鼠标或代理抖一次都不能写负缓存，
        // 否则下一次 hover / 重开详情会直接跳过真正的 GIF 探测，整个进程内永不动画。
        guard !Task.isCancelled, outcome != .inconclusive else { return .inconclusive }
        Self.memoryCache.setObject(NSNumber(value: outcome == .animatedGIF), forKey: key)
        return outcome
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
    ) -> ProbeOutcome {
        // 读不到属性/数据多为瞬态 IO（外置卷未挂载、文件正被写入）：不写负缓存。
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return .inconclusive
        }
        guard fileSize.int64Value <= maxByteCount else { return .notAnimated }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return .inconclusive
        }
        guard dataLooksLikeGIF(data) else { return .notAnimated }

        return imagePropertiesWithinBudget(
            data,
            maxPixelCount: maxPixelCount,
            maxFrameCount: maxFrameCount,
            requireAnimatedFrameCount: true
        ) ? .animatedGIF : .notAnimated
    }

    private static func probeRemoteGIF(
        _ url: URL,
        maxByteCount: Int64,
        maxPixelCount: Int,
        maxFrameCount: Int
    ) async -> ProbeOutcome {
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 网络瞬态失败（代理 TLS 抖动 / 超时 / 断连）：结论未知，不写负缓存。
            return .inconclusive
        }
        guard !data.isEmpty else { return .inconclusive }
        // 服务器错误（403 挑战 / 5xx）同样可能是瞬态，不能据此判死「非 GIF」。
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            return http.statusCode == 404 ? .notAnimated : .inconclusive
        }
        if Int64(data.count) > maxByteCount {
            return .notAnimated
        }
        if let byteCount = estimatedByteCount(from: response), byteCount > maxByteCount {
            return .notAnimated
        }

        let mimeType = response.mimeType?.lowercased() ?? ""
        let looksLikeGIF = mimeType.contains("gif") || dataLooksLikeGIF(data)
        guard looksLikeGIF else { return .notAnimated }

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
            ) ? .animatedGIF : .notAnimated
        }
        return gifHeaderDimensionsWithinBudget(data, maxPixelCount: maxPixelCount)
            ? .animatedGIF : .notAnimated
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
    /// 同路径文件内容被覆盖后（如详情页「重新抽帧」）强制跳过缓存重读一次。
    var forceRefresh: Bool = false
    /// 当前卡片/视图是否在视口内；非「仅悬停播放」模式下，离屏时停动画。
    var isVisible: Bool = true
    /// `true` 时仅在 `isHovered == true` 时解码播放 GIF（列表/网格推荐，显著减轻滚动时主线程压力）。
    var animateOnHoverOnly: Bool = false
    /// 配合 `animateOnHoverOnly`；由卡片 `onHover` / `throttledHover` 传入。
    var isHovered: Bool = false
    /// 加载失败（非取消）时调用：静帧层失败，或 GIF 动画层失败（此时静帧兜底仍可能可用）。
    /// 详情页据此提供「重试」入口；列表/网格不传则维持原占位行为。
    var loadFailed: (() -> Void)? = nil
    /// 完整成功时调用：静帧成功且未发生动画层失败，或动画层成功。
    /// 与 `loadFinished`（成功/失败都触发）分开，供详情页清除失败态。
    var loadSucceeded: (() -> Void)? = nil

    @State private var detectedGIF = false
    @State private var animatedLoadFailed = false
    /// 取消/瞬态失败后的自动重试代次：KFImage binder 在 cancelOnDisappear 取消后
    /// 不会自发重启（placeholder 的 onAppear 不会再次触发），必须换 id 重建。
    @State private var loadRetryEpoch = 0
    @State private var loadRetryTask: Task<Void, Never>?
    @State private var loadRetryCount = 0
    /// 任一层已成功解码：阻止「重建→旧 binder 取消→再重试」自喂养环。
    @State private var anyLayerLoaded = false
    /// 内存复位后的补探测任务：换 URL / 离屏时取消，防旧结论写回新 URL。
    @State private var reprobeTask: Task<Void, Never>?

    private var shouldShowStaticLayer: Bool {
        !detectedGIF || animatedLoadFailed
    }

    private var shouldAnimate: Bool {
        guard playAnimatedImage, coverGIFPlaybackHostActive else { return false }
        if animateOnHoverOnly {
            return isHovered
        }
        return isVisible
    }

    /// `KFAnimatedImage` 的 `configure` 只在 makeNSView 跑一次，且 `autoPlayAnimatedImage`
    /// 是无 didSet 的普通属性：建视图时算出的播放开关定终身。把最终播放决策纳入 `id`，
    /// 开关变化（悬停进出 / 宿主活跃翻转 / 可见性变化）强制重建以应用新值。
    /// 仅悬停模式下 shouldAnimate 已含 isHovered，统一覆盖旧 hover 专用 id。
    private var kfAnimatedLayerIdentity: String {
        "\(url.absoluteString)|play:\(shouldAnimate)"
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
        // 闭包捕获本代次：被重建替换的旧 binder 的取消回调不再触发重试，
        // 否则「重建→旧 binder 取消→再重建」自喂养，冷缓存下载永远跑不完。
        let retryEpoch = loadRetryEpoch
        let core = ZStack {
            underlay
            // 静态层只负责非 GIF 或动画加载失败的封面；确认 GIF 后释放，避免静态图和动画层长期双持有。
            if shouldShowStaticLayer {
                KFImage(url)
                    .wh_optionalDownsample(downsampleSize)
                    .cacheMemoryOnly(false)
                    .forceRefresh(forceRefresh)
                    .cancelOnDisappear(true)
                    .fade(duration: fadeDuration)
                    .placeholder { _ in underlay }
                    .onSuccess { result in
                        anyLayerLoaded = true
                        loadRetryCount = 0
                        if !detectedGIF, result.image.kf.gifRepresentation() != nil {
                            detectedGIF = true
                        } else if !detectedGIF {
                            loadSucceeded?()
                        }
                        loadFinished?()
                    }
                    .onFailure { error in
                        // 取消（离屏 / 切页 / 同 URL 下载被其它消费者掐断）不是失败：
                        // 不亮重试，但短暂延迟后换 id 重建 binder 自动续载。
                        // KFImage 的 placeholder onAppear 取消后不会再触发，
                        // 不重建就永远停在渐变占位（详情背景「半天加载不出来」）。
                        if error.isTaskCancelled {
                            scheduleLoadRetry(forEpoch: retryEpoch)
                            return
                        }
                        loadFailed?()
                        loadFinished?()
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // 重试代次参与身份：取消后重建 binder 才会重新发起加载。
                    .id(retryEpoch)
            }

            // 2. 若真实格式为 GIF 且允许动画，叠加 KFAnimatedImage 播放动效
            if detectedGIF && !animatedLoadFailed {
                KFAnimatedImage.url(url)
                    .memoryCacheExpiration(.expired)
                    .diskCacheExpiration(.days(3))
                    .forceRefresh(forceRefresh)
                    .cancelOnDisappear(true)
                    .configure { view in
                        configureAnimatedGIFViewForAspectFill(view, autoPlay: shouldAnimate)
                    }
                    .placeholder { _ in underlay }
                    .onSuccess { _ in
                        anyLayerLoaded = true
                        loadRetryCount = 0
                        loadSucceeded?()
                        loadFinished?()
                    }
                    .onFailure { error in
                        if error.isTaskCancelled {
                            // 同静帧层：被掐断的动画层下载也要续载，否则定格/空底。
                            scheduleLoadRetry(forEpoch: retryEpoch)
                            return
                        }
                        // 动画层失败回退静帧层（shouldShowStaticLayer），同时上报失败
                        // 让详情页给出重试入口——静帧兜底可能仍是渐变占位。
                        animatedLoadFailed = true
                        loadFailed?()
                        loadFinished?()
                    }
                    // id 随最终播放决策变化：AppKit 侧不会响应已建视图的 `autoPlayAnimatedImage` 更新。
                    // 重试代次同样参与：取消后重建才会重新下载。
                    .id("\(kfAnimatedLayerIdentity)|retry:\(retryEpoch)")
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
            loadRetryTask?.cancel()
            loadRetryTask = nil
            reprobeTask?.cancel()
            reprobeTask = nil
            loadRetryEpoch = 0
            loadRetryCount = 0
            anyLayerLoaded = false
            detectedGIF = false
            animatedLoadFailed = false
            // 探针始终运行以检测真实内容是否为 GIF，不依赖 URL 后缀启发式。
            // animated 参数仅用于 shouldAnimate（控制动画播放），不影响检测逻辑。
            let result = await AnimatedImageProbeCache.shared.isAnimatedGIF(url)
            guard !Task.isCancelled else { return }
            detectedGIF = result
        }
        .onDisappear {
            loadRetryTask?.cancel()
            loadRetryTask = nil
            reprobeTask?.cancel()
            reprobeTask = nil
        }
        // 内存释放 / 内存压力复位 detectedGIF 后必须重新探测：
        // .task(id: url) 不重跑，探针结论丢了就永远停在静帧。
        .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
            resetAndReprobe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidReceiveMemoryPressure)) { _ in
            resetAndReprobe()
        }
    }

    private func resetAndReprobe() {
        loadRetryTask?.cancel()
        loadRetryTask = nil
        reprobeTask?.cancel()
        loadRetryEpoch = 0
        loadRetryCount = 0
        anyLayerLoaded = false
        detectedGIF = false
        animatedLoadFailed = false
        let target = url
        reprobeTask = Task { @MainActor in
            let result = await AnimatedImageProbeCache.shared.isAnimatedGIF(target)
            guard !Task.isCancelled else { return }
            detectedGIF = result
        }
    }

    /// 下载被取消（同 URL 的其它消费者掐断了共享 URLSession 任务 / 离屏取消）后，
    /// 短暂延迟换 id 重建两层 binder 续载。KF 的 placeholder onAppear 在取消后
    /// 不会再次触发，不重建就永远停在渐变占位。
    /// 防环：任一层已成功不再重试；连续取消最多 3 次；离屏 / 换 URL 取消排队。
    private func scheduleLoadRetry(forEpoch epoch: Int) {
        // 旧代 binder（已被重建替换）的取消不算数，防自喂养环。
        guard epoch == loadRetryEpoch else { return }
        guard !anyLayerLoaded else { return }
        guard loadRetryCount < 3 else {
            // 连续被掐断 3 次：不再自动重建，亮手动重试入口兜底。
            loadFailed?()
            loadFinished?()
            return
        }
        guard loadRetryTask == nil else { return }
        loadRetryCount += 1
        loadRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            // 睡眠期间被换 URL / 离屏取消时 task 已被置 nil；仍持有旧句柄说明没人清理，
            // 这里兜底释放，避免后续取消分支被「已有排队」guard 永久挡住。
            loadRetryTask = nil
            guard !anyLayerLoaded, loadRetryEpoch == epoch else { return }
            loadRetryEpoch &+= 1
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
