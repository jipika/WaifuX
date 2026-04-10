import SwiftUI
import Combine
import CryptoKit
import AVFoundation

// MARK: - 轻量级图片加载器
// 优化策略：
// 1. 使用 actor 保证线程安全
// 2. 磁盘 I/O 在后台线程执行，通过 await 切换
// 3. 内存缓存使用 NSCache（线程安全）

public actor ImageLoader {
    public static let shared = ImageLoader()

    // MARK: - 缓存配置
    // ⚠️ NSCache 是线程安全的，标记为 nonisolated(unsafe) 允许同步访问
    private nonisolated(unsafe) let memoryCache = NSCache<NSString, NSImage>()
    private let cacheDirectory: URL
    
    // MARK: - 并发控制
    private let maxConcurrentLoads = 6
    private var activeLoadCount = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    
    // MARK: - 失败追踪
    private var failedURLs: Set<String> = []
    private let maxFailedURLs = 100
    private var retryAttempts: [String: Int] = [:]
    private let maxRetryAttempts = 3
    
    // MARK: - URLSession
    private nonisolated let urlSession: URLSession
    
    // MARK: - 重试配置
    public struct RetryConfig: Sendable {
        public let maxAttempts: Int
        public let baseDelay: TimeInterval
        public let maxDelay: TimeInterval
        public let exponentialBackoff: Bool
        public let retryableStatusCodes: Set<Int>
        
        public init(
            maxAttempts: Int,
            baseDelay: TimeInterval,
            maxDelay: TimeInterval,
            exponentialBackoff: Bool,
            retryableStatusCodes: Set<Int>
        ) {
            self.maxAttempts = maxAttempts
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
            self.exponentialBackoff = exponentialBackoff
            self.retryableStatusCodes = retryableStatusCodes
        }
        
        public static let `default` = RetryConfig(
            maxAttempts: 3,
            baseDelay: 1.0,
            maxDelay: 8.0,
            exponentialBackoff: true,
            retryableStatusCodes: [408, 429, 500, 502, 503, 504]
        )
        
        public static let none = RetryConfig(
            maxAttempts: 1,
            baseDelay: 0,
            maxDelay: 0,
            exponentialBackoff: false,
            retryableStatusCodes: []
        )
    }

    // MARK: - 初始化
    private init() {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100MB

        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = urls[0].appendingPathComponent("WallHaven/ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // URLSession 配置
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        urlSession = URLSession(configuration: config)
        
        setupMemoryPressureHandler()
    }
    
    private nonisolated func setupMemoryPressureHandler() {
        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.handleMemoryPressure()
            }
        }
        source.resume()
        #endif
    }
    
    private func handleMemoryPressure() {
        memoryCache.removeAllObjects()
    }

    // MARK: - 公共 API
    
    /// 检查内存缓存（nonisolated，支持从 SwiftUI 同步调用）
    /// NSCache 本身是线程安全的
    public nonisolated func cachedImage(for url: URL) -> NSImage? {
        memoryCache.object(forKey: url.absoluteString as NSString)
    }

    public func loadImage(
        from url: URL,
        priority: TaskPriority = .medium,
        targetSize: CGSize? = nil,
        retryConfig: RetryConfig = .default
    ) async -> NSImage? {
        let key = url.absoluteString
        
        // 1. 检查内存缓存
        if let cached = memoryCache.object(forKey: key as NSString) {
            return targetSize != nil ? await downsampleAsync(image: cached, to: targetSize!) : cached
        }
        
        // 2. 磁盘缓存在后台线程读取
        if let diskCached = await loadFromDiskAsync(key: key) {
            memoryCache.setObject(diskCached, forKey: key as NSString)
            return targetSize != nil ? await downsampleAsync(image: diskCached, to: targetSize!) : diskCached
        }
        
        // 3. 检查失败记录
        guard !failedURLs.contains(key) else { return nil }
        
        // 4. 本地文件直接读取
        if url.isFileURL {
            return await loadLocalImage(from: url, key: key, targetSize: targetSize)
        }
        
        // 5. 网络图片加载
        return await loadImageWithRetry(
            from: url,
            key: key,
            priority: priority,
            targetSize: targetSize,
            retryConfig: retryConfig,
            attempt: 1
        )
    }
    
    // MARK: - 磁盘缓存（异步，不阻塞 actor）
    
    private nonisolated func loadFromDiskAsync(key: String) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let fileURL = self.cacheDirectory.appendingPathComponent(key.md5)
            guard let data = try? Data(contentsOf: fileURL),
                  let image = NSImage(data: data) else {
                return nil
            }
            return image
        }.value
    }
    
    private nonisolated func saveToDiskAsync(data: Data, key: String) {
        Task.detached(priority: .utility) {
            let fileURL = self.cacheDirectory.appendingPathComponent(key.md5)
            try? data.write(to: fileURL)
        }
    }
    
    // MARK: - 本地图片加载
    
    private func loadLocalImage(from url: URL, key: String, targetSize: CGSize?) async -> NSImage? {
        await waitForSlot()
        defer { releaseSlot() }
        
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            
            // 视频文件生成缩略图
            if self.isVideoFile(url) {
                return await self.generateVideoThumbnail(from: url)
            }
            
            guard let image = NSImage(data: data) else { return nil }
            return image
        }.value
    }
    
    // MARK: - 网络图片加载（带重试）
    private func loadImageWithRetry(
        from url: URL,
        key: String,
        priority: TaskPriority,
        targetSize: CGSize?,
        retryConfig: RetryConfig,
        attempt: Int
    ) async -> NSImage? {
        // 检查重试次数
        let currentAttempt = retryAttempts[key] ?? 0
        guard currentAttempt < maxRetryAttempts else {
            failedURLs.insert(key)
            return nil
        }
        retryAttempts[key] = currentAttempt + 1
        
        // 等待并发槽位
        await waitForSlot()
        defer { releaseSlot() }
        
        await Task.yield()
        
        do {
            let (data, response) = try await urlSession.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            
            // 检查是否需要重试
            if retryConfig.retryableStatusCodes.contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            
            guard httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            // 验证图片数据
            guard let image = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            
            // 缓存
            memoryCache.setObject(image, forKey: key as NSString, cost: data.count)
            saveToDiskAsync(data: data, key: key)
            
            // 清除重试记录
            retryAttempts.removeValue(forKey: key)
            
            return targetSize != nil ? await downsampleAsync(image: image, to: targetSize!) : image
            
        } catch {
            // 计算重试延迟
            let delay = retryConfig.exponentialBackoff
                ? min(retryConfig.baseDelay * pow(2.0, Double(attempt - 1)), retryConfig.maxDelay)
                : retryConfig.baseDelay
            
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            return await loadImageWithRetry(
                from: url,
                key: key,
                priority: priority,
                targetSize: targetSize,
                retryConfig: retryConfig,
                attempt: attempt + 1
            )
        }
    }
    
    // MARK: - 并发控制
    
    private func waitForSlot() async {
        if activeLoadCount < maxConcurrentLoads {
            activeLoadCount += 1
            return
        }
        
        await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
        }
    }
    
    private func releaseSlot() {
        if let waiter = loadWaiters.first {
            loadWaiters.removeFirst()
            waiter.resume()
        } else {
            activeLoadCount = max(0, activeLoadCount - 1)
        }
    }
    
    // MARK: - 降采样
    
    private nonisolated func downsampleAsync(image: NSImage, to targetSize: CGSize) async -> NSImage {
        await Task.detached(priority: .utility) {
            image.downsampled(to: targetSize)
        }.value
    }
    
    // MARK: - 视频缩略图
    
    private nonisolated func generateVideoThumbnail(from url: URL) async -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }
    
    private nonisolated func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
    
    // MARK: - 内存清理
    
    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    
    public func clearAllCache() {
        memoryCache.removeAllObjects()
        Task.detached {
            try? FileManager.default.removeItem(at: self.cacheDirectory)
            try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - 失败状态管理
    
    public func hasFailedLoading(for url: URL) -> Bool {
        failedURLs.contains(url.absoluteString)
    }
    
    public func resetFailureState(for url: URL) {
        failedURLs.remove(url.absoluteString)
        retryAttempts.removeValue(forKey: url.absoluteString)
    }
    
    // MARK: - 批量预加载（兼容旧代码）
    
    public func prefetchImages(urls: [URL]) {
        for url in urls {
            Task {
                _ = await loadImage(from: url, priority: .low)
            }
        }
    }
    
    // MARK: - 取消加载（兼容旧代码）
    
    public func cancelLoad(for url: URL) {
        // 新版依赖 Task cancellation，不再单独追踪
    }
    
    public func cancelAllLoads() {
        // 简化实现
    }
}

// MARK: - ImagePreloader（兼容旧代码）

@MainActor
final class ImagePreloader {
    static let shared = ImagePreloader()
    
    func preloadImages(from urls: [URL]) {
        Task {
            for url in urls {
                _ = await ImageLoader.shared.loadImage(from: url, priority: .low)
            }
        }
    }
}

// MARK: - OptimizedAsyncImage

public struct OptimizedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let priority: TaskPriority
    let targetSize: CGSize?
    let retryConfig: ImageLoader.RetryConfig
    let onLoad: (() -> Void)?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    
    @State private var image: NSImage?
    @State private var isVisible = false
    @State private var loadTask: Task<Void, Never>?
    
    public init(
        url: URL?,
        priority: TaskPriority = .medium,
        targetSize: CGSize? = nil,
        retryConfig: ImageLoader.RetryConfig = .default,
        onLoad: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.priority = priority
        self.targetSize = targetSize
        self.retryConfig = retryConfig
        self.onLoad = onLoad
        self.content = content
        self.placeholder = placeholder
    }
    
    public var body: some View {
        Group {
            if let image = image {
                content(Image(nsImage: image))
            } else {
                placeholder()
            }
        }
        .onAppear {
            isVisible = true
            // ⚠️ 先同步检查内存缓存 — 避免异步加载导致的闪烁
            if let url = url, image == nil,
               let cached = ImageLoader.shared.cachedImage(for: url) {
                self.image = cached
                onLoad?()
                return
            }
            loadTask?.cancel()
            loadTask = Task { await load() }
        }
        .onDisappear {
            isVisible = false
            // 只取消进行中的网络请求，不清空已加载的图片
            loadTask?.cancel()
            loadTask = nil
        }
        .onChange(of: url) { _, _ in
            image = nil
            loadTask?.cancel()
            if isVisible {
                // 同步检查缓存
                if let url = url, let cached = ImageLoader.shared.cachedImage(for: url) {
                    self.image = cached
                    onLoad?()
                    return
                }
                loadTask = Task { await load() }
            }
        }
    }
    
    private func load() async {
        guard let url = url, isVisible else { return }
        
        if let loadedImage = await ImageLoader.shared.loadImage(
            from: url,
            priority: priority,
            targetSize: targetSize,
            retryConfig: retryConfig
        ) {
            guard !Task.isCancelled else { return }
            image = loadedImage
            onLoad?()
        }
    }
}

// MARK: - String MD5 扩展

extension String {
    var md5: String {
        let data = Data(self.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - 图片降采样扩展
private extension NSImage {
    func downsampled(to targetSize: CGSize) -> NSImage {
        var sourceRect = CGRect(origin: .zero, size: self.size)
        let targetRect = CGRect(origin: .zero, size: targetSize)
        
        guard let cgImage = self.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil) else {
            return self
        }
        
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        
        bitmap.size = targetSize
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        
        let drawRect = CGRect(origin: .zero, size: targetSize)
        self.draw(in: drawRect, from: sourceRect, operation: .copy, fraction: 1.0)
        
        NSGraphicsContext.restoreGraphicsState()
        
        let result = NSImage(size: targetSize)
        result.addRepresentation(bitmap)
        return result
    }
}
