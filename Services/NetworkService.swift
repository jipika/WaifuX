import Foundation

actor NetworkService {
    static let shared = NetworkService()

    private let session: URLSession
    private let cache: URLCache
    
    // MARK: - Retry Configuration
    private var defaultRetryConfig: RetryConfiguration = .default
    private var networkMonitor: NetworkMonitor? = nil

    private init() {
        // 配置 URLCache
        let cache = URLCache(
            memoryCapacity: 50_000_000,  // 50 MB 内存缓存
            diskCapacity: 200_000_000,   // 200 MB 磁盘缓存
            diskPath: "WallHavenCache"
        )
        self.cache = cache

        // 配置 URLSession - 使用缓存以减少重复请求
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad  // 使用缓存加快加载
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60  // 资源超时时间
        config.urlCache = cache
        // 允许蜂窝网络访问
        config.allowsCellularAccess = true
        // 等待网络连接
        config.waitsForConnectivity = true
        // 启用后台会话
        config.isDiscretionary = false

        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Retry Configuration
    
    /// 设置默认重试配置
    func setDefaultRetryConfiguration(_ config: RetryConfiguration) {
        self.defaultRetryConfig = config
    }
    
    /// 设置网络监测器 (用于根据网络质量调整重试策略)
    func setNetworkMonitor(_ monitor: NetworkMonitor) {
        self.networkMonitor = monitor
    }
    
    /// 获取当前有效的重试配置
    private func effectiveRetryConfiguration(_ customConfig: RetryConfiguration? = nil) -> RetryConfiguration {
        if let custom = customConfig {
            return custom
        }
        
        // 暂时使用默认配置，避免访问NetworkMonitor的@MainActor属性
        // 后续可以通过其他方式实现网络质量检测
        return defaultRetryConfig
    }

    // MARK: - Public API with Retry
    
    /// 获取 API 数据（⚠️ 禁用缓存，每次重新请求）
    func fetch<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        headers: [String: String] = [:],
        retryConfig: RetryConfiguration? = nil
    ) async throws -> T {
        let config = effectiveRetryConfiguration(retryConfig)
        
        return try await executeWithRetry(config: config, operation: { attempt in
            // ⚠️ API 请求禁用缓存
            let data = try await self.fetchDataInternal(from: url, headers: headers, attempt: attempt, useCache: false)
            
            let decoder = JSONDecoder()
            do {
                let result = try decoder.decode(T.self, from: data)
                return result
            } catch {
                throw error
            }
        })
    }

    // MARK: - Data Fetching with Retry
    
    /// 获取数据（⚠️ 禁用缓存，每次重新请求）
    func fetchData(
        from url: URL,
        headers: [String: String] = [:],
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        retryConfig: RetryConfiguration? = nil
    ) async throws -> Data {
        let config = effectiveRetryConfiguration(retryConfig)
        
        return try await executeWithRetry(config: config) { attempt in
            // ⚠️ 数据请求禁用缓存
            try await self.fetchDataInternal(from: url, headers: headers, attempt: attempt, progressHandler: progressHandler, useCache: false)
        }
    }
    
    // MARK: - Internal Implementation
    
    private func fetchDataInternal(
        from url: URL,
        headers: [String: String] = [:],
        attempt: Int = 1,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        useHosts: Bool = true,  // 是否使用 hosts 加速
        useCache: Bool = true   // 是否使用缓存（图片用 true，API 请求用 false）
    ) async throws -> Data {
        
        // 构建请求
        func buildRequest(for targetURL: URL, withHost host: String?) -> URLRequest {
            var request = URLRequest(url: targetURL)
            // ⚠️ 控制缓存策略：API 请求禁用缓存，图片请求使用缓存
            if !useCache {
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            }
            if let host = host {
                request.setValue(host, forHTTPHeaderField: "Host")
            }
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            return request
        }
        
        // 尝试使用 hosts 加速
        if useHosts && GitHubHosts.isEnabled && GitHubHosts.isGitHubURL(url.absoluteString) {
            let (requestURL, hostHeader) = Self.resolveGitHubURL(url)
            
            // 只有当 hosts 解析成功时才尝试
            if hostHeader != nil {
                let request = buildRequest(for: requestURL, withHost: hostHeader)
                
                do {
                    let data = try await performRequest(request: request, progressHandler: progressHandler)
                    return data
                } catch {
                    // GitHub Hosts 失败，回退到原始域名
                }
            }
        }
        
        // 使用原始域名请求
        let request = buildRequest(for: url, withHost: nil)
        return try await performRequest(request: request, progressHandler: progressHandler)
    }
    
    /// 执行网络请求
    private func performRequest(
        request: URLRequest,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        
        if let progressHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }

            let expectedLength = response.expectedContentLength
            let chunkSize = 32 * 1024
            var receivedLength: Int64 = 0
            var data = Data()
            var buffer: [UInt8] = []
            buffer.reserveCapacity(chunkSize)

            progressHandler(expectedLength > 0 ? 0.0 : 0.08)

            for try await byte in bytes {
                buffer.append(byte)

                if buffer.count >= chunkSize {
                    data.append(contentsOf: buffer)
                    receivedLength += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)

                    if expectedLength > 0 {
                        progressHandler(min(max(Double(receivedLength) / Double(expectedLength), 0.0), 1.0))
                    }
                }
            }

            if !buffer.isEmpty {
                data.append(contentsOf: buffer)
                receivedLength += Int64(buffer.count)
            }

            if expectedLength > 0 {
                progressHandler(min(max(Double(receivedLength) / Double(expectedLength), 0.0), 1.0))
            } else {
                progressHandler(1.0)
            }

            return data
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode)
        }

        return data
    }

    func fetchString(from url: URL, headers: [String: String] = [:]) async throws -> String {
        let data = try await fetchData(from: url, headers: headers)
        return String(decoding: data, as: UTF8.self)
    }
    
    func fetchImage(
        from url: URL,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        retryConfig: RetryConfiguration? = nil
    ) async throws -> Data {
        let config = effectiveRetryConfiguration(retryConfig)
        
        return try await executeWithRetry(config: config) { attempt in
            let data = try await self.fetchDataInternal(from: url, attempt: attempt, progressHandler: progressHandler)
            return data
        }
    }
    
    // MARK: - 缓存管理
    
    /// 清除所有缓存
    func clearCache() {
        cache.removeAllCachedResponses()
    }
    
    /// 清除特定 URL 的缓存
    func clearCache(for url: URL) {
        let request = URLRequest(url: url)
        cache.removeCachedResponse(for: request)
    }
    
    /// 获取缓存大小
    func getCacheSize() -> String {
        let memorySize = cache.currentMemoryUsage
        let diskSize = cache.currentDiskUsage
        let totalSize = memorySize + diskSize
        
        if totalSize < 1024 {
            return "\(totalSize) bytes"
        } else if totalSize < 1024 * 1024 {
            return "\(String(format: "%.2f", Double(totalSize) / 1024)) KB"
        } else {
            return "\(String(format: "%.2f", Double(totalSize) / (1024 * 1024))) MB"
        }
    }
    
    // MARK: - Retry Logic
    
    private func executeWithRetry<T>(
        config: RetryConfiguration,
        operation: (Int) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...(config.maxRetries + 1) {
            do {
                let result = try await operation(attempt)
                return result
            } catch {
                lastError = error
                
                // 检查是否应该重试
                guard attempt <= config.maxRetries else {
                    break
                }
                
                // 检查错误是否可重试
                guard error.isRetryable else {
                    throw error
                }
                
                // 检查是否取消
                if error is CancellationError {
                    throw error
                }
                
                // 计算延迟时间
                let delay = config.delayForRetry(attempt: attempt)
                
                // 等待延迟时间
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                // 再次检查是否取消
                try Task.checkCancellation()
            }
        }
        
        // 所有重试都失败了
        throw lastError ?? NetworkError.networkError(URLError(.unknown))
    }
}
