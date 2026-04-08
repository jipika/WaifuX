import SwiftUI
import Combine
import CryptoKit

// MARK: - 轻量级图片加载器
// 优化策略：
// 1. 移除复杂的 actor 并发控制，使用简单的计数器
// 2. 简化 LRU 磁盘缓存，减少数组操作
// 3. 降采样移到后台线程
// 4. 移除重复的状态追踪

@MainActor
public final class ImageLoader {
    public static let shared = ImageLoader()

    // MARK: - 缓存配置
    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // MARK: - 简单并发控制（无 actor 开销）
    private let maxConcurrentLoads = 6
    private var activeLoadCount = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    
    // MARK: - URLSession（简化配置）
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        // 只用内存缓存，磁盘缓存自己管理
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    
    // MARK: - 简单失败追踪
    private var failedURLs: Set<String> = []
    private let maxFailedURLs = 100
    
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
    
    // MARK: - 重试状态追踪
    private var retryAttempts: [String: Int] = [:]
    private let maxRetryAttempts = 3

    // MARK: - 初始化
    private init() {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100MB

        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = urls[0].appendingPathComponent("WallHaven/ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // 内存压力处理
        setupMemoryPressureHandler()
    }
    
    private func setupMemoryPressureHandler() {
        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.memoryCache.removeAllObjects()
        }
        source.resume()
        #endif
    }

    // MARK: - 公共方法

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
        
        // 2. 检查磁盘缓存
        if let diskCached = loadFromDisk(key: key) {
            memoryCache.setObject(diskCached, forKey: key as NSString)
            return targetSize != nil ? await downsampleAsync(image: diskCached, to: targetSize!) : diskCached
        }
        
        // 3. 检查是否永久失败（手动标记的）
        guard !failedURLs.contains(key) else { return nil }
        
        // 4. 执行带重试的加载
        return await loadImageWithRetry(
            from: url,
            key: key,
            priority: priority,
            targetSize: targetSize,
            retryConfig: retryConfig,
            attempt: 1
        )
    }
    
    /// 带重试机制的图片加载
    private func loadImageWithRetry(
        from url: URL,
        key: String,
        priority: TaskPriority,
        targetSize: CGSize?,
        retryConfig: RetryConfig,
        attempt: Int
    ) async -> NSImage? {
        // 等待并发槽位
        await waitForSlot()
        defer { releaseSlot() }
        
        // 再次检查缓存（可能其他任务已加载）
        if let cached = memoryCache.object(forKey: key as NSString) {
            // 清除重试记录（成功）
            retryAttempts.removeValue(forKey: key)
            return targetSize != nil ? await downsampleAsync(image: cached, to: targetSize!) : cached
        }
        
        do {
            let (data, response) = try await urlSession.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                recordFailure(key: key)
                return nil
            }
            
            // 检查是否需要重试
            if retryConfig.retryableStatusCodes.contains(httpResponse.statusCode) {
                return await handleRetryableFailure(
                    from: url, key: key, priority: priority, targetSize: targetSize,
                    retryConfig: retryConfig, attempt: attempt,
                    statusCode: httpResponse.statusCode
                )
            }
            
            // 检查是否成功
            guard (200...299).contains(httpResponse.statusCode),
                  let image = NSImage(data: data) else {
                // 非重试错误，记录失败
                if attempt >= retryConfig.maxAttempts {
                    recordFailure(key: key)
                }
                return nil
            }
            
            // 成功：清除重试记录
            retryAttempts.removeValue(forKey: key)
            
            // 后台保存到磁盘
            let cacheDir = cacheDirectory
            Task.detached(priority: .utility) {
                let fileURL = cacheDir.appendingPathComponent(key.md5)
                try? data.write(to: fileURL)
            }
            
            // 存入内存缓存
            memoryCache.setObject(image, forKey: key as NSString, cost: data.count)
            
            // 应用降采样
            if let targetSize = targetSize {
                return await downsampleAsync(image: image, to: targetSize)
            }
            return image
            
        } catch {
            // 网络错误，尝试重试
            return await handleRetryableFailure(
                from: url, key: key, priority: priority, targetSize: targetSize,
                retryConfig: retryConfig, attempt: attempt,
                statusCode: nil, error: error
            )
        }
    }
    
    /// 处理可重试的失败
    private func handleRetryableFailure(
        from url: URL,
        key: String,
        priority: TaskPriority,
        targetSize: CGSize?,
        retryConfig: RetryConfig,
        attempt: Int,
        statusCode: Int?,
        error: Error? = nil
    ) async -> NSImage? {
        guard attempt < retryConfig.maxAttempts else {
            // 达到最大重试次数
            recordFailure(key: key)
            retryAttempts.removeValue(forKey: key)
            return nil
        }
        
        // 计算延迟时间
        let delay: TimeInterval
        if retryConfig.exponentialBackoff {
            delay = min(retryConfig.baseDelay * pow(2.0, Double(attempt - 1)), retryConfig.maxDelay)
        } else {
            delay = retryConfig.baseDelay
        }
        
        // 记录重试次数
        retryAttempts[key] = attempt
        
        // 延迟后重试
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        
        // 检查是否被取消
        guard !Task.isCancelled else { return nil }
        
        return await loadImageWithRetry(
            from: url,
            key: key,
            priority: priority,
            targetSize: targetSize,
            retryConfig: retryConfig,
            attempt: attempt + 1
        )
    }
    
    // MARK: - 简单并发控制
    
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
    
    // MARK: - 磁盘缓存（简化版）
    
    private func loadFromDisk(key: String) -> NSImage? {
        let fileURL = cacheDirectory.appendingPathComponent(key.md5)
        guard let data = try? Data(contentsOf: fileURL),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }
    
    private func saveToDisk(data: Data, key: String) {
        let fileURL = cacheDirectory.appendingPathComponent(key.md5)
        try? data.write(to: fileURL)
        
        // 简单清理：每 100 次保存检查一次
        if Int.random(in: 0...99) == 0 {
            cleanupDiskCacheIfNeeded()
        }
    }
    
    private func cleanupDiskCacheIfNeeded() {
        let contents = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        
        var totalSize: Int64 = 0
        var files: [(url: URL, size: Int64, date: Date)] = []
        
        for file in contents {
            guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? Int64,
                  let date = attrs[.modificationDate] as? Date else { continue }
            totalSize += size
            files.append((file, size, date))
        }
        
        // 超过 300MB 就清理
        guard totalSize > 300 * 1024 * 1024 else { return }
        
        // 按修改时间排序，删除最旧的
        let sorted = files.sorted { $0.date < $1.date }
        var deletedSize: Int64 = 0
        let targetSize = Int64(Double(totalSize) * 0.7) // 保留 70%
        
        for file in sorted {
            guard totalSize - deletedSize > targetSize else { break }
            try? fileManager.removeItem(at: file.url)
            deletedSize += file.size
        }
    }
    
    // MARK: - 失败追踪
    
    private func recordFailure(key: String) {
        if failedURLs.count < maxFailedURLs {
            failedURLs.insert(key)
        }
    }
    
    // MARK: - 降采样（后台线程）
    
    private func downsampleAsync(image: NSImage, to size: CGSize) async -> NSImage {
        await Task.detached(priority: .utility) { [image] in
            self.downsample(image: image, to: size)
        }.value
    }
    
    /// 同步降采样（非隔离，可在后台线程调用）
    nonisolated private func downsample(image: NSImage, to size: CGSize) -> NSImage {
        // 如果图片已经够小，直接返回
        if image.size.width <= size.width && image.size.height <= size.height {
            return image
        }
        
        let aspectRatio = image.size.width / image.size.height
        let targetAspectRatio = size.width / size.height
        
        let targetSize: NSSize
        if aspectRatio > targetAspectRatio {
            targetSize = NSSize(width: size.width, height: size.width / aspectRatio)
        } else {
            targetSize = NSSize(width: size.height * aspectRatio, height: size.height)
        }
        
        // 使用 2x Retina
        let retinaSize = NSSize(width: targetSize.width * 2, height: targetSize.height * 2)
        
        guard let bitmapRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                  pixelsWide: Int(retinaSize.width),
                                                  pixelsHigh: Int(retinaSize.height),
                                                  bitsPerSample: 8,
                                                  samplesPerPixel: 4,
                                                  hasAlpha: true,
                                                  isPlanar: false,
                                                  colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0,
                                                  bitsPerPixel: 0) else {
            return image
        }
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        
        image.draw(in: NSRect(origin: .zero, size: retinaSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        
        NSGraphicsContext.restoreGraphicsState()
        
        let result = NSImage(size: targetSize)
        result.addRepresentation(bitmapRep)
        return result
    }
    
    // MARK: - 清理
    
    public func clearCache() {
        memoryCache.removeAllObjects()
        let contents = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in contents {
            try? fileManager.removeItem(at: file)
        }
        retryAttempts.removeAll()
    }
    
    /// 获取URL的重试次数
    public func getRetryAttempts(for url: URL) -> Int {
        retryAttempts[url.absoluteString] ?? 0
    }
    
    /// 重置重试状态
    public func resetRetryState(for url: URL) {
        retryAttempts.removeValue(forKey: url.absoluteString)
        failedURLs.remove(url.absoluteString)
    }
    
    // MARK: - 预加载
    
    public nonisolated func prefetchImages(urls: [URL]) {
        Task(priority: .low) { [weak self] in
            for url in urls.prefix(10) {
                _ = await self?.loadImage(from: url, priority: .low)
                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms 间隔
            }
        }
    }
}

// MARK: - 性能优化的图片视图
@MainActor
public struct OptimizedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let priority: TaskPriority
    let targetSize: CGSize?
    let retryConfig: ImageLoader.RetryConfig
    let onLoad: (() -> Void)?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    
    private let loader = ImageLoader.shared
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
            loadTask?.cancel()
            loadTask = Task { await load() }
        }
        .onDisappear {
            isVisible = false
            loadTask?.cancel()
            loadTask = nil
            if let url = url {
                loader.cancelLoad(for: url)
            }
        }
        .onChange(of: url) { _, _ in
            image = nil
            loadTask?.cancel()
            if isVisible {
                loadTask = Task { await load() }
            }
        }
    }
    
    private func load() async {
        guard let url = url, isVisible else { return }
        
        if let loadedImage = await loader.loadImage(
            from: url,
            priority: priority,
            targetSize: targetSize,
            retryConfig: retryConfig
        ) {
            guard isVisible else { return }
            image = loadedImage
            onLoad?()
        }
    }
}

// MARK: - 批量预加载
@MainActor
final class ImagePreloader {
    static let shared = ImagePreloader()
    
    private let loader = ImageLoader.shared
    
    func preloadImages(from urls: [URL]) {
        loader.prefetchImages(urls: urls)
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

// MARK: - 取消加载（兼容旧代码）
extension ImageLoader {
    func cancelLoad(for url: URL) {
        // 新版不再单独追踪任务，依赖 Task cancellation
    }
    
    func cancelAllLoads() {
        // 简化实现
    }
    
    public func resetFailureState(for url: URL) {
        failedURLs.remove(url.absoluteString)
    }
    
    public func hasFailedLoading(for url: URL) -> Bool {
        failedURLs.contains(url.absoluteString)
    }
}
