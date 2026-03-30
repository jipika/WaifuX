import SwiftUI
import Combine
import CryptoKit

// MARK: - 性能优化的图片加载器
// 优化内容：
// 1. 使用 NSCache 进行内存缓存（带 cost 计算）
// 2. LRU 磁盘缓存（最大 500MB）
// 3. 限制同时加载的图片数量
// 4. 支持 Task cancellation
// 5. 加载优先级管理
// 6. 渐进式加载支持

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    // MARK: - 缓存配置
    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    // MARK: - LRU 磁盘缓存
    private var diskCacheKeys: [String] = []
    private let maxDiskCacheSize: Int = 500 * 1024 * 1024 // 500MB
    private let maxMemoryCacheSize: Int = 150 * 1024 * 1024 // 150MB

    // MARK: - 并发控制（使用 AsyncChannel 避免 QoS 优先级反转）
    private let maxConcurrentLoads = 4
    private var activeTasks: [String: Task<Data?, Error>] = [:]
    
    // MARK: - 重试配置
    private let imageRetryConfig = RetryConfiguration(
        maxRetries: 2,
        initialDelay: 0.5,
        maxDelay: 4.0,
        delayMultiplier: 2.0,
        allowRetryOnCellular: true
    )
    
    // MARK: - 错误跟踪
    private var failedURLs: Set<String> = []
    private let maxRetryPerURL = 3
    private var urlRetryCounts: [String: Int] = [:]

    // MARK: - 初始化
    private init() {
        // 配置内存缓存
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = maxMemoryCacheSize

        // 配置磁盘缓存目录
        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = urls[0].appendingPathComponent("WallHaven/ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // 加载磁盘缓存索引
        loadDiskCacheIndex()

        // 启动缓存清理任务
        Task {
            await cleanupDiskCacheIfNeeded()
        }
    }

    // MARK: - 并发控制（使用 AsyncChannel 避免 QoS 优先级反转）
    private actor LoadLimiter {
        private var availableSlots: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(slots: Int) {
            self.availableSlots = slots
        }

        func acquire() async {
            if availableSlots > 0 {
                availableSlots -= 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            if let waiter = waiters.first {
                waiters.removeFirst()
                waiter.resume()
            } else {
                availableSlots += 1
            }
        }
    }

    private let loadLimiter = LoadLimiter(slots: 4)

    // MARK: - 公共方法
    
    /// 加载图片（支持取消、优先级和重试）
    func loadImage(
        from url: URL,
        priority: TaskPriority = .medium,
        retryConfig: RetryConfiguration? = nil
    ) async -> NSImage? {
        let key = url.absoluteString
        let config = retryConfig ?? imageRetryConfig
        
        // 检查是否已有正在进行的任务
        if let existingTask = activeTasks[key] {
            return try? await existingTask.value.flatMap { NSImage(data: $0) }
        }
        
        // 检查内存缓存
        if let cached = getFromMemoryCache(key: key) {
            return cached
        }
        
        // 检查磁盘缓存
        if let diskCached = getFromDiskCache(key: key) {
            setToMemoryCache(diskCached, key: key)
            return diskCached
        }
        
        // 检查是否之前已经失败太多次
        if failedURLs.contains(key) {
            print("[ImageLoader] ⚠️ URL previously failed, skipping: \(url.lastPathComponent)")
            return nil
        }
        
        // 创建新的加载任务
        let task = Task<Data?, Error>(priority: priority) { [weak self] in
            guard let self = self else { return nil }
            
            return try await self.loadImageWithRetry(from: url, key: key, config: config)
        }
        
        activeTasks[key] = task
        
        // 等待任务完成
        do {
            let data = try await task.value
            activeTasks.removeValue(forKey: key)
            // 成功加载后清除失败记录
            failedURLs.remove(key)
            urlRetryCounts.removeValue(forKey: key)
            return data.flatMap { NSImage(data: $0) }
        } catch {
            activeTasks.removeValue(forKey: key)
            // 记录失败
            await self.recordFailure(for: key)
            return nil
        }
    }
    
    /// 带重试的图片加载
    private func loadImageWithRetry(
        from url: URL,
        key: String,
        config: RetryConfiguration
    ) async throws -> Data? {
        var lastError: Error?
        
        for attempt in 1...(config.maxRetries + 1) {
            do {
                return try await self.loadImageOnce(from: url, key: key)
            } catch {
                lastError = error
                
                // 检查是否应该重试
                guard attempt <= config.maxRetries else {
                    break
                }
                
                // 检查是否可重试
                guard error.isRetryable else {
                    print("[ImageLoader] ❌ Error not retryable: \(error.localizedDescription)")
                    throw error
                }
                
                // 检查是否取消
                if error is CancellationError {
                    throw error
                }
                
                // 计算延迟
                let delay = config.delayForRetry(attempt: attempt)
                print("[ImageLoader] ⏱️ Retrying image load in \(String(format: "%.1f", delay))s... (attempt \(attempt + 1)/\(config.maxRetries + 1))")
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
            }
        }
        
        print("[ImageLoader] ❌ All attempts failed for: \(url.lastPathComponent)")
        throw lastError ?? NetworkError.invalidResponse
    }
    
    /// 单次图片加载
    private func loadImageOnce(from url: URL, key: String) async throws -> Data? {
        // 使用 Swift 并发友好的方式控制并发
        await self.loadLimiter.acquire()
        defer { Task { await self.loadLimiter.release() } }
        
        // 再次检查缓存（可能其他任务已加载）
        if let cached = self.getFromMemoryCache(key: key) {
            return cached.tiffRepresentation
        }
        if let diskCached = self.getFromDiskCache(key: key) {
            return diskCached.tiffRepresentation
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            // 检查任务是否被取消
            try Task.checkCancellation()
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError.invalidResponse
            }
            
            // 在后台线程解码图片
            if let image = await self.decodeImageInBackground(data: data) {
                let cost = data.count
                self.setToMemoryCache(image, key: key, cost: cost)
                await self.saveToDiskCache(data: data, key: key)
            }
            
            return data
        } catch is CancellationError {
            return nil
        } catch {
            throw error
        }
    }
    
    /// 记录失败
    private func recordFailure(for key: String) async {
        let currentCount = urlRetryCounts[key, default: 0] + 1
        urlRetryCounts[key] = currentCount
        
        if currentCount >= maxRetryPerURL {
            failedURLs.insert(key)
            print("[ImageLoader] 🚫 Marked as permanently failed after \(maxRetryPerURL) attempts: \(key.prefix(50))...")
        }
    }
    
    /// 重置特定 URL 的失败状态 (用于手动重试)
    func resetFailureState(for url: URL) {
        let key = url.absoluteString
        failedURLs.remove(key)
        urlRetryCounts.removeValue(forKey: key)
    }
    
    /// 检查 URL 是否加载失败过
    func hasFailedLoading(for url: URL) -> Bool {
        failedURLs.contains(url.absoluteString)
    }
    
    /// 渐进式加载：先加载缩略图，再加载高清图
    func loadImageProgressive(
        thumbURL: URL,
        fullURL: URL,
        priority: TaskPriority = .medium
    ) async -> (thumb: NSImage?, full: NSImage?) {
        // 先加载缩略图
        let thumb = await loadImage(from: thumbURL, priority: priority)
        
        // 如果缩略图加载成功，再加载高清图
        let full = await loadImage(from: fullURL, priority: .low)
        
        return (thumb, full)
    }
    
    /// 取消特定图片的加载
    func cancelLoad(for url: URL) {
        let key = url.absoluteString
        activeTasks[key]?.cancel()
        activeTasks.removeValue(forKey: key)
    }
    
    /// 取消所有加载任务
    func cancelAllLoads() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }
    
    /// 预加载图片（低优先级）
    func preloadImage(from url: URL) {
        Task(priority: .low) {
            _ = await loadImage(from: url, priority: .low)
        }
    }
    
    /// 智能预加载：只预加载指定范围内的图片
    func preloadImages(from urls: [URL], around visibleIndices: [Int], radius: Int = 5) {
        let targetIndices = visibleIndices.flatMap { index -> [Int] in
            ((index - radius)...(index + radius)).filter { $0 >= 0 && $0 < urls.count }
        }
        
        let uniqueIndices = Set(targetIndices).sorted()
        
        Task(priority: .low) {
            for index in uniqueIndices.prefix(10) { // 最多预加载10张
                _ = await loadImage(from: urls[index], priority: .low)
            }
        }
    }
    
    /// 清理缓存
    func clearCache() async {
        memoryCache.removeAllObjects()
        
        let contents = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in contents {
            try? fileManager.removeItem(at: file)
        }
        
        diskCacheKeys.removeAll()
        saveDiskCacheIndex()
    }
    
    /// 获取缓存大小
    var cacheSize: Int {
        let contents = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.reduce(0) { total, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
    }
    
    // MARK: - 私有方法
    
    private func decodeImageInBackground(data: Data) async -> NSImage? {
        await Task.detached(priority: .low) {
            NSImage(data: data)
        }.value
    }
    
    // MARK: - 内存缓存
    
    private func getFromMemoryCache(key: String) -> NSImage? {
        memoryCache.object(forKey: key as NSString)
    }
    
    private func setToMemoryCache(_ image: NSImage, key: String, cost: Int = 0) {
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }
    
    // MARK: - 磁盘缓存（带 LRU）
    
    private func getFromDiskCache(key: String) -> NSImage? {
        let fileURL = cacheDirectory.appendingPathComponent(key.md5)
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        // 更新 LRU 顺序
        if let index = diskCacheKeys.firstIndex(of: key) {
            diskCacheKeys.remove(at: index)
            diskCacheKeys.append(key)
            saveDiskCacheIndex()
        }
        
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }
    
    private func saveToDiskCache(data: Data, key: String) async {
        let fileURL = cacheDirectory.appendingPathComponent(key.md5)
        
        // 如果已存在，先删除旧文件
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
            diskCacheKeys.removeAll { $0 == key }
        }
        
        // 写入新文件
        do {
            try data.write(to: fileURL)
            diskCacheKeys.append(key)
            saveDiskCacheIndex()
            
            // 检查是否需要清理
            await cleanupDiskCacheIfNeeded()
        } catch {
            print("[ImageLoader] Failed to save to disk cache: \(error)")
        }
    }
    
    private func cleanupDiskCacheIfNeeded() async {
        let currentSize = cacheSize
        
        guard currentSize > maxDiskCacheSize else { return }
        
        // 按 LRU 顺序删除，直到低于阈值的 80%
        let targetSize = Int(Double(maxDiskCacheSize) * 0.8)
        var removedSize = 0
        
        for key in diskCacheKeys {
            let fileURL = cacheDirectory.appendingPathComponent(key.md5)
            
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? Int {
                try? fileManager.removeItem(at: fileURL)
                removedSize += fileSize
                diskCacheKeys.removeAll { $0 == key }
            }
            
            if currentSize - removedSize <= targetSize {
                break
            }
        }
        
        saveDiskCacheIndex()
        print("[ImageLoader] Cleaned up disk cache, removed \(removedSize / 1024 / 1024)MB")
    }
    
    private func loadDiskCacheIndex() {
        let indexFile = cacheDirectory.appendingPathComponent("cache_index.json")
        
        guard let data = try? Data(contentsOf: indexFile),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        
        diskCacheKeys = keys
    }
    
    private func saveDiskCacheIndex() {
        let indexFile = cacheDirectory.appendingPathComponent("cache_index.json")
        
        if let data = try? JSONEncoder().encode(diskCacheKeys) {
            try? data.write(to: indexFile)
        }
    }
}

// MARK: - 性能优化的图片视图（渐进式加载）
@MainActor
public struct OptimizedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let priority: TaskPriority
    let onLoad: (() -> Void)?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    
    private let loader = ImageLoader.shared
    @State private var image: NSImage?
    @State private var isVisible = false
    
    public init(
        url: URL?,
        priority: TaskPriority = .medium,
        onLoad: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.priority = priority
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
            // 延迟加载，避免快速滚动时立即触发
            isVisible = true
            Task {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms 延迟
                if isVisible {
                    loadImage()
                }
            }
        }
        .onDisappear {
            isVisible = false
            // 不立即取消，让图片有机会缓存
        }
        .onChange(of: url) { _, newURL in
            image = nil
            if isVisible, let newURL {
                Task {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if isVisible {
                        loadImage()
                    }
                }
            }
        }
    }
    
    private func loadImage() {
        guard let url = url, isVisible else { return }
        
        Task {
            if let loadedImage = await loader.loadImage(from: url, priority: priority) {
                await MainActor.run {
                    self.image = loadedImage
                    self.onLoad?()
                }
            }
        }
    }
    
    private func cancelLoad() {
        guard let url = url else { return }
        loader.cancelLoad(for: url)
    }
}

// MARK: - 渐进式加载图片视图（缩略图 -> 高清图）
@MainActor
struct ProgressiveImageView<Content: View>: View {
    let thumbURL: URL?
    let fullURL: URL?
    let priority: TaskPriority
    @ViewBuilder let content: (Image, Bool) -> Content // (image, isFullImage)
    
    private let loader = ImageLoader.shared
    @State private var thumbImage: NSImage?
    @State private var fullImage: NSImage?
    @State private var isVisible = false
    
    init(
        thumbURL: URL?,
        fullURL: URL?,
        priority: TaskPriority = .medium,
        @ViewBuilder content: @escaping (Image, Bool) -> Content
    ) {
        self.thumbURL = thumbURL
        self.fullURL = fullURL
        self.priority = priority
        self.content = content
    }
    
    var body: some View {
        Group {
            if let full = fullImage {
                content(Image(nsImage: full), true)
            } else if let thumb = thumbImage {
                content(Image(nsImage: thumb), false)
            } else {
                content(Image(systemName: "photo"), false)
            }
        }
        .onAppear {
            isVisible = true
            loadImages()
        }
        .onDisappear {
            isVisible = false
            cancelLoads()
        }
    }
    
    private func loadImages() {
        guard isVisible else { return }
        
        Task {
            // 先加载缩略图
            if let thumbURL = thumbURL {
                thumbImage = await loader.loadImage(from: thumbURL, priority: priority)
            }
            
            // 再加载高清图（低优先级）
            if let fullURL = fullURL, fullURL != thumbURL {
                fullImage = await loader.loadImage(from: fullURL, priority: .low)
            }
        }
    }
    
    private func cancelLoads() {
        if let thumbURL = thumbURL {
            loader.cancelLoad(for: thumbURL)
        }
        if let fullURL = fullURL {
            loader.cancelLoad(for: fullURL)
        }
    }
}

// MARK: - 批量图片预加载器
@MainActor
final class ImagePreloader {
    static let shared = ImagePreloader()
    
    private let loader = ImageLoader.shared
    private var preloadTasks: [String: Task<Void, Never>] = [:]
    
    /// 预加载一组图片
    func preloadImages(from urls: [URL], maxConcurrent: Int = 2) {
        // 取消之前的预加载任务
        cancelAllPreloads()
        
        Task(priority: .low) {
            await withTaskGroup(of: Void.self) { group in
                var count = 0
                
                for url in urls {
                    if count >= maxConcurrent {
                        await group.next()
                        count -= 1
                    }
                    
                    group.addTask { [weak self] in
                        _ = await self?.loader.loadImage(from: url, priority: .low)
                    }
                    count += 1
                }
            }
        }
    }
    
    /// 取消所有预加载
    func cancelAllPreloads() {
        for (_, task) in preloadTasks {
            task.cancel()
        }
        preloadTasks.removeAll()
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
