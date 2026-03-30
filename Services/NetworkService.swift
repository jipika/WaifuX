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
        config.urlCache = cache
        // 允许蜂窝网络访问
        config.allowsCellularAccess = true
        // 等待网络连接
        config.waitsForConnectivity = true

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
        return defaultRetryConfig
    }

    // MARK: - Public API with Retry
    
    func fetch<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        headers: [String: String] = [:],
        retryConfig: RetryConfiguration? = nil
    ) async throws -> T {
        let config = effectiveRetryConfiguration(retryConfig)
        
        return try await executeWithRetry(config: config, operation: { attempt in
            print("[NetworkService] 🌐 Fetching (attempt \(attempt)): \(url.absoluteString)")
            
            let data = try await self.fetchDataInternal(from: url, headers: headers, attempt: attempt)
            
            if let jsonString = String(data: data, encoding: .utf8) {
                print("[NetworkService] 📥 Response: \(jsonString.prefix(500))...")
            }
            
            let decoder = JSONDecoder()
            do {
                let result = try decoder.decode(T.self, from: data)
                print("[NetworkService] ✅ Decode success")
                return result
            } catch {
                print("[NetworkService] ❌ Decode error: \(error)")
                // 打印更多解码错误详情
                if let jsonObject = try? JSONSerialization.jsonObject(with: data),
                   let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
                   let prettyString = String(data: prettyData, encoding: .utf8) {
                    print("[NetworkService] 📄 JSON structure: \(prettyString.prefix(1000))")
                }
                throw error
            }
        })
    }

    // MARK: - Data Fetching with Retry
    
    func fetchData(
        from url: URL,
        headers: [String: String] = [:],
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        retryConfig: RetryConfiguration? = nil
    ) async throws -> Data {
        let config = effectiveRetryConfiguration(retryConfig)
        
        return try await executeWithRetry(config: config) { attempt in
            try await self.fetchDataInternal(from: url, headers: headers, attempt: attempt, progressHandler: progressHandler)
        }
    }
    
    // MARK: - Internal Implementation
    
    private func fetchDataInternal(
        from url: URL,
        headers: [String: String] = [:],
        attempt: Int = 1,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        print("[NetworkService] 📤 Starting request to: \(url.absoluteString) (attempt \(attempt))")
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        print("[NetworkService] 📋 Request headers: \(headers)")
        print("[NetworkService] ⏳ Awaiting response from: \(url.absoluteString)")

        if let progressHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[NetworkService] ❌ Invalid response type")
                throw NetworkError.invalidResponse
            }

            print("[NetworkService] 📊 Status code: \(httpResponse.statusCode) for \(url.absoluteString)")

            guard (200...299).contains(httpResponse.statusCode) else {
                print("[NetworkService] ❌ HTTP error: \(httpResponse.statusCode)")
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

            print("[NetworkService] 📥 Received response: \(data.count) bytes from \(url.absoluteString)")
            return data
        }

        let (data, response) = try await session.data(for: request)
        print("[NetworkService] 📥 Received response: \(data.count) bytes from \(url.absoluteString)")

        // 打印响应内容（截断）
        if let content = String(data: data, encoding: .utf8) {
            let preview = content.prefix(2000)
            print("[NetworkService] 📄 Response content preview:\n\(preview)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[NetworkService] ❌ Invalid response type")
            throw NetworkError.invalidResponse
        }

        print("[NetworkService] 📊 Status code: \(httpResponse.statusCode) for \(url.absoluteString)")

        guard (200...299).contains(httpResponse.statusCode) else {
            print("[NetworkService] ❌ HTTP error: \(httpResponse.statusCode)")
            throw NetworkError.httpError(httpResponse.statusCode)
        }

        return data
    }

    func fetchString(from url: URL, headers: [String: String] = [:]) async throws -> String {
        print("[NetworkService] fetchString called: \(url.absoluteString)")
        print("[NetworkService] headers: \(headers)")
        let data = try await fetchData(from: url, headers: headers)
        let result = String(decoding: data, as: UTF8.self)
        print("[NetworkService] fetchString result length: \(result.count)")
        print("[NetworkService] fetchString preview: \(result.prefix(500))")
        return result
    }

    func fetchImage(
        from url: URL,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        retryConfig: RetryConfiguration? = nil
    ) async throws -> Data {
        let config = effectiveRetryConfiguration(retryConfig)
        
        return try await executeWithRetry(config: config) { attempt in
            print("[NetworkService] 🖼️ Fetching image: \(url.absoluteString) (attempt \(attempt))")
            let data = try await self.fetchDataInternal(from: url, attempt: attempt, progressHandler: progressHandler)
            print("[NetworkService] ✅ Image fetched: \(data.count) bytes")
            return data
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
                // 如果成功且有之前的错误，记录重试成功
                if attempt > 1 {
                    print("[NetworkService] ✅ Request succeeded after \(attempt) attempts")
                }
                return result
            } catch {
                lastError = error
                
                // 检查是否应该重试
                guard attempt <= config.maxRetries else {
                    break
                }
                
                // 检查错误是否可重试
                guard error.isRetryable else {
                    print("[NetworkService] ❌ Error not retryable: \(error)")
                    throw error
                }
                
                // 检查是否取消
                if error is CancellationError {
                    throw error
                }
                
                // 计算延迟时间
                let delay = config.delayForRetry(attempt: attempt)
                print("[NetworkService] ⏱️ Retrying in \(String(format: "%.1f", delay))s... (attempt \(attempt + 1)/\(config.maxRetries + 1))")
                
                // 等待延迟时间
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                // 再次检查是否取消
                try Task.checkCancellation()
            }
        }
        
        // 所有重试都失败了
        print("[NetworkService] ❌ All \(config.maxRetries + 1) attempts failed")
        throw lastError ?? NetworkError.networkError(URLError(.unknown))
    }
}
