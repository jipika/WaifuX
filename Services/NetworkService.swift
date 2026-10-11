import Foundation

actor NetworkService {
    static let shared = NetworkService()

    /// 常规会话：未显式设置 connectionProxyDictionary 时跟随系统代理。
    private var session: URLSession
    /// 直连会话：显式清空 connectionProxyDictionary 覆盖系统代理。
    /// 只给对出口 IP 敏感的源使用（Wallsflow 的 Cloudflare 挑战按出口下发：
    /// 走本机 FastStunnel 出口必被挑战，直连则放行）。
    private let directSession: URLSession
    private let cache: URLCache
    private var proxySettings: ProxySettings
    #if DEBUG
    private(set) var proxySessionGeneration: UInt64 = 0
    #endif

    private struct ProxySettings: Equatable {
        let host: String?
        let port: Int?

        init(enabled: Bool, host: String, port: String) {
            if enabled, !host.isEmpty, let number = Int(port), number > 0 {
                self.host = host
                self.port = number
            } else {
                self.host = nil
                self.port = nil
            }
        }
    }

    // MARK: - Retry Configuration
    private var defaultRetryConfig: RetryConfiguration = .default
    private var networkMonitor: NetworkMonitor? = nil

    /// 基础配置：所有会话共用（缓存 / 超时 / Cookie / 蜂窝）。
    private static func makeConfiguration(proxy: ProxySettings? = nil) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad  // 使用缓存加快加载
        // 媒体整文件下载可达数十 MB；60s 资源超时会导致 Wallsflow 等大 MP4 中途失败。
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 900
        config.urlCache = URLCache.shared
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        // 允许蜂窝网络访问
        config.allowsCellularAccess = true
        // 等待网络连接
        config.waitsForConnectivity = true
        // 启用后台会话
        config.isDiscretionary = false
        if let host = proxy?.host, let port = proxy?.port {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host,
                kCFNetworkProxiesHTTPSPort: port
            ]
        }
        return config
    }

    private init() {
        // 使用全局 URLCache.shared（已在 WaifuXApp.swift 中配置），避免重复缓存层
        self.cache = URLCache.shared

        let preferences = WaifuXPreferences.shared
        let proxy = ProxySettings(enabled: preferences.bool(forKey: "proxy_enabled"),
                                  host: preferences.string(forKey: "proxy_host") ?? "",
                                  port: preferences.string(forKey: "proxy_port") ?? "")
        self.proxySettings = proxy
        self.session = URLSession(configuration: Self.makeConfiguration(proxy: proxy))

        // 空字典 = 不使用任何代理（覆盖系统代理设置）；不要传 nil，nil 会继续跟随系统设置。
        let directConfig = Self.makeConfiguration()
        directConfig.connectionProxyDictionary = [:]
        self.directSession = URLSession(configuration: directConfig)
    }

    // MARK: - Proxy Configuration

    func updateProxyConfiguration(enabled: Bool, host: String, port: String) {
        let next = ProxySettings(enabled: enabled, host: host, port: port)
        guard next != proxySettings else { return }
        let previous = session
        session = URLSession(configuration: Self.makeConfiguration(proxy: next))
        proxySettings = next
        // Finish existing downloads on their original connection while allowing
        // future requests to use the new proxy, then release the old session.
        previous.finishTasksAndInvalidate()
        #if DEBUG
        proxySessionGeneration &+= 1
        #endif
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
    /// - Parameter bypassSystemProxy: true 时改用直连会话（显式清空代理，覆盖系统代理设置）。
    func fetchData(
        from url: URL,
        headers: [String: String] = [:],
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        retryConfig: RetryConfiguration? = nil,
        bypassSystemProxy: Bool = false
    ) async throws -> Data {
        let config = effectiveRetryConfiguration(retryConfig)

        return try await executeWithRetry(config: config) { attempt in
            // ⚠️ 数据请求禁用缓存
            try await self.fetchDataInternal(from: url, headers: headers, attempt: attempt, progressHandler: progressHandler, useCache: false, bypassSystemProxy: bypassSystemProxy)
        }
    }

    /// 使用自定义 URLRequest 获取数据（支持 POST body、自定义 method 等）
    func fetchData(
        request: URLRequest,
        retryConfig: RetryConfiguration? = nil
    ) async throws -> Data {
        let config = effectiveRetryConfiguration(retryConfig)
        return try await executeWithRetry(config: config) { _ in
            try await self.performRequest(request: request, progressHandler: nil)
        }
    }

    // MARK: - Internal Implementation

    private func fetchDataInternal(
        from url: URL,
        headers: [String: String] = [:],
        attempt: Int = 1,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        useHosts: Bool = true,  // 是否使用 hosts 加速
        useCache: Bool = true,   // 是否使用缓存（图片用 true，API 请求用 false）
        bypassSystemProxy: Bool = false  // 是否走直连会话（覆盖系统代理）
    ) async throws -> Data {
        let requestSession: URLSession? = bypassSystemProxy ? directSession : nil

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
                    let data = try await performRequest(request: request, progressHandler: progressHandler, session: requestSession)
                    return data
                } catch {
                    // GitHub Hosts 失败，回退到原始域名
                }
            }
        }

        // 使用原始域名请求
        let request = buildRequest(for: url, withHost: nil)
        return try await performRequest(request: request, progressHandler: progressHandler, session: requestSession)
    }

    /// 执行网络请求
    /// - Parameter session: 指定会话（如直连会话）；nil 时用跟随系统代理的常规会话。
    private func performRequest(
        request: URLRequest,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        session: URLSession? = nil
    ) async throws -> Data {
        let session = session ?? self.session

        if let progressHandler {
            // 大文件（Wallsflow ~几十 MB）绝不能 `for try await byte` 逐字节挂起，
            // 否则极慢且易触发资源超时，最终落盘失败或只拿到热链 HTML。
            // 使用 download 任务写临时文件，再读入 Data；进度用字节计数近似。
            progressHandler(0.02)
            let (tempURL, response) = try await session.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                try? FileManager.default.removeItem(at: tempURL)
                let cfMitigated = httpResponse.value(forHTTPHeaderField: "cf-mitigated")?.lowercased()
                if cfMitigated == "challenge" || httpResponse.statusCode == 503 {
                    let server = httpResponse.value(forHTTPHeaderField: "server")?.lowercased() ?? ""
                    if server.contains("cloudflare") || cfMitigated == "challenge" {
                        throw NetworkError.loginRequired(
                            message: "请求被 Cloudflare 反爬拦截。请在「设置 → 代理」启用 VPN/代理后重试。"
                        )
                    }
                }
                throw NetworkError.httpError(httpResponse.statusCode)
            }

            progressHandler(0.92)
            let data = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
            try? FileManager.default.removeItem(at: tempURL)
            progressHandler(1.0)
            return data
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Cloudflare 挑战页检测（响应头或响应体）
            let statusCode = httpResponse.statusCode
            if statusCode == 403 || statusCode == 503 {
                let cfMitigated = httpResponse.value(forHTTPHeaderField: "cf-mitigated")?.lowercased()
                let server = httpResponse.value(forHTTPHeaderField: "server")?.lowercased() ?? ""
                let isCloudflare = server.contains("cloudflare") || cfMitigated == "challenge"
                let bodyHintsCF: Bool = {
                    guard let text = String(data: data.prefix(2048), encoding: .utf8) else { return false }
                    return text.contains("Just a moment") || text.contains("challenges.cloudflare")
                }()
                if isCloudflare || bodyHintsCF {
                    throw NetworkError.loginRequired(
                        message: "请求被 Cloudflare 反爬拦截。请在「设置 → 代理」启用 VPN/代理后重试。"
                    )
                }
            }
            throw NetworkError.httpError(statusCode)
        }

        return data
    }

    func fetchString(from url: URL, headers: [String: String] = [:], bypassSystemProxy: Bool = false) async throws -> String {
        let data = try await fetchData(from: url, headers: headers, bypassSystemProxy: bypassSystemProxy)
        return String(decoding: data, as: UTF8.self)
    }

    func fetchImage(
        from url: URL,
        headers: [String: String] = [:],
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        retryConfig: RetryConfiguration? = nil,
        bypassSystemProxy: Bool = false
    ) async throws -> Data {
        let config = effectiveRetryConfiguration(retryConfig)

        return try await executeWithRetry(config: config) { attempt in
            let data = try await self.fetchDataInternal(
                from: url,
                headers: headers,
                attempt: attempt,
                progressHandler: progressHandler,
                bypassSystemProxy: bypassSystemProxy
            )
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
