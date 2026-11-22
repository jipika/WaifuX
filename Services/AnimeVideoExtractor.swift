import Foundation
import WebKit
import Combine
import OSLog

// MARK: - Video Extraction Result

enum VideoExtractionResult {
    case success([VideoSource])
    case error(String)
    case captcha
    case timeout
}

/// Browser evidence stays attached to a candidate until its request headers are built.
/// VideoSource remains the public playback/download contract.
struct AnimeMediaCandidate {
    let url: URL
    let format: String
    let sourceKind: String
    let frameURL: String
    let pageURL: String
    let referrer: String
    let userAgent: String
    let confidence: Int
    let responseStatus: Int?

    static func pathFormat(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "m3u8"
        case "mp4", "m4v": return "mp4"
        case "mov", "webm", "mkv", "flv", "mpd": return url.pathExtension.lowercased()
        default: return nil
        }
    }

    static func mimeFormat(_ value: String) -> String? {
        switch value.lowercased().split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl": return "m3u8"
        case "application/dash+xml": return "mpd"
        case "video/mp4", "video/x-m4v": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "video/x-matroska": return "mkv"
        case "video/x-flv": return "flv"
        default: return nil
        }
    }

    static func isSegment(_ url: URL) -> Bool {
        ["ts", "m4s", "m4a", "aac", "vtt", "key"].contains(url.pathExtension.lowercased())
    }

    /// Kazumi legacy 解析（decodeVideoSource）：老式播放器把媒体直链放在 iframe src 的
    /// query 参数里（如 player.php?url=https://cdn/xx.m3u8）。返回第一个命中的媒体 URL。
    static func legacyEmbeddedMediaURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8192 else { return nil }
        let expanded = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        let decoded = expanded.removingPercentEncoding ?? expanded
        guard let components = URLComponents(string: decoded) else { return nil }
        for item in components.queryItems ?? [] {
            guard let value = item.value,
                  let match = value.range(of: #"https?://[^\s"'<>]+?\.(m3u8|mp4)(?=[&#\s"'<>]|$)"#,
                                          options: [.regularExpression, .caseInsensitive]) else { continue }
            let candidate = String(value[match]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
            if let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               url.host != nil, !isSegment(url), pathFormat(url) != nil {
                return url.absoluteString
            }
        }
        return nil
    }

    /// 已确认的广告网络宿主（Kazumi contentBlockers 同款 + 常见广告 CDN）。
    /// 命中宿主的媒体候选一律丢弃，防止广告视频挤掉正片。
    static func isAdHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let adSuffixes = ["googlesyndication.com", "doubleclick.net", "googleadservices.com",
                          "adservice.google.com", "adtrafficquality.google", "googletagservices.com",
                          "adsystem.com", "adnxs.com", "adsrvr.org", "taboola.com", "outbrain.com",
                          "popads.net", "popcash.net", "propellerads.com", "exoclick.com",
                          "juicyads.com", "trafficjunky.com", "hilltopads.com", "adcash.com",
                          "magsrv.com", "mnaspm.com", "bbrdbr.com"]
        return adSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func decode(_ payload: [String: Any], fallbackFrame: URL?, pageURL: String) -> AnimeMediaCandidate? {
        guard let rawURL = payload["url"] as? String,
              let url = URL(string: rawURL, relativeTo: fallbackFrame)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, !isSegment(url), !isAdHost(url) else { return nil }
        let kind = payload["sourceKind"] as? String ?? "unknown"
        // A raw iframe src is a document; "legacy-iframe" carries only a media URL already
        // extracted from the frame's query parameters (Kazumi useLegacyParser path).
        guard ["fetch-response", "xhr-response", "navigation-response", "media-element", "media-hint", "network-request", "legacy-iframe"].contains(kind) else { return nil }
        let rawStatus = (payload["status"] as? NSNumber)?.intValue
        let status = rawStatus.flatMap { $0 > 0 ? $0 : nil }
        if let status, !(200...299).contains(status) { return nil }
        let mime = (payload["contentType"] as? String ?? "").lowercased()
        guard !mime.contains("text/html"), !mime.contains("application/xhtml"),
              !mime.contains("video/mp2t") else { return nil }
        let evidence = payload["evidence"] as? String ?? ""
        let responseKind = ["fetch-response", "xhr-response", "navigation-response"].contains(kind)
        let responseFormat = mimeFormat(mime)
        let bodyFormat = evidence == "hls-body" && responseKind ? "m3u8" : nil
        let declaredFormat = mimeFormat(payload["format"] as? String ?? "")
        // readyState proves an extensionless video element decoded media; it remains below
        // response evidence and uses the player's generic asset path when no container is declared.
        let elementFormat = kind == "media-element" ? (declaredFormat ?? "mp4") : nil
        let format = bodyFormat ?? responseFormat ?? pathFormat(url) ?? elementFormat
        guard let format else { return nil }
        let confidence: Int
        if bodyFormat != nil { confidence = 100 }
        else if responseKind, responseFormat != nil { confidence = 95 }
        else if responseKind { confidence = 85 }
        else if kind == "media-element" { confidence = 75 }
        // A declared media URL inside the player frame's query is strong evidence, but the
        // bytes are unverified; the playback preflight settles it before ranking matters.
        else if kind == "legacy-iframe" { confidence = 70 }
        else { confidence = 45 }
        return AnimeMediaCandidate(
            url: url, format: format, sourceKind: kind,
            frameURL: payload["frameURL"] as? String ?? fallbackFrame?.absoluteString ?? pageURL,
            pageURL: payload["pageURL"] as? String ?? pageURL,
            referrer: payload["referrer"] as? String ?? fallbackFrame?.absoluteString ?? pageURL,
            userAgent: payload["userAgent"] as? String ?? "",
            confidence: confidence, responseStatus: status
        )
    }
}

@MainActor
class AnimeVideoExtractor: NSObject, ObservableObject {
    static let shared = AnimeVideoExtractor()
    static let defaultBrowserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let logger = Logger(subsystem: "com.waifux.app", category: "AnimeVideoExtractor")

    @Published var isLoading = false
    @Published var progressMessage = ""
    @Published var logMessages: [String] = []

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<VideoExtractionResult, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var videoFoundTask: Task<Void, Never>?
    private var directHLSProbe: Task<Void, Never>?
    private var allowsDirectMXdmHLS = false
    private var resolveId = 0
    private var candidates: [String: AnimeMediaCandidate] = [:]
    private var currentRule: AnimeRule?
    private var currentPageURL = ""
    private var startedAt = Date()
    private var lastImprovementAt = Date()
    private var firstConfirmedAt: Date?
    private var navigationReferrers: [String: String] = [:]
    private var dataStore = WKWebsiteDataStore.nonPersistent()

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.contains("\r"), !value.contains("\n") else { return nil }
        return value
    }

    static func effectiveUserAgent(rule: AnimeRule, observed: String? = nil) -> String {
        let header = rule.headers?.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }.flatMap { nonempty($0.value) }
        return nonempty(rule.userAgent) ?? header ?? nonempty(observed) ?? defaultBrowserUserAgent
    }

    static func requestHeaders(for url: URL, rule: AnimeRule, pageURL: String, userAgent: String? = nil) -> [String: String] {
        var request = URLRequest(url: url)
        for (key, value) in rule.headers ?? [:] {
            if let value = nonempty(value), key.caseInsensitiveCompare("Cookie") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        request.setValue(effectiveUserAgent(rule: rule, observed: userAgent), forHTTPHeaderField: "User-Agent")
        if request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue(nonempty(rule.referer) ?? nonempty(pageURL), forHTTPHeaderField: "Referer")
        }
        // A literal Cookie header has no domain metadata. Limit it to the rule's origin;
        // WebKit/shared-store cookies below retain their own domain/path/secure scope.
        if url.host?.lowercased() == URL(string: rule.baseURL)?.host?.lowercased(),
           let cookie = rule.headers?.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }).flatMap({ nonempty($0.value) }) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        } else {
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            if !cookies.isEmpty {
                request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
            }
        }
        return request.allHTTPHeaderFields ?? [:]
    }

    func extractVideoSources(from episodeURL: String, rule: AnimeRule, timeout: TimeInterval = 30,
                             allowDirectMXdmHLS: Bool = false) async -> VideoExtractionResult {
        cancelAndCleanup()
        guard !Task.isCancelled else { return .error("已取消") }
        allowsDirectMXdmHLS = allowDirectMXdmHLS
        currentRule = rule
        currentPageURL = episodeURL
        logMessages.removeAll()
        guard let url = URL(string: episodeURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            return .error(LocalizationService.shared.t("无效的视频链接"))
        }
        // Only the actual path extension can activate the direct shortcut.
        if let format = AnimeMediaCandidate.pathFormat(url) {
            var source = VideoSource(quality: Self.quality(url: url, format: format), url: url.absoluteString, type: format, label: nil)
            source.httpHeaders = Self.requestHeaders(for: url, rule: rule, pageURL: rule.baseURL)
            addLog("检测到媒体直链 host=\(Self.safeHost(url)) format=\(format)")
            return .success([source])
        }
        let requestID = resolveId
        startedAt = Date()
        lastImprovementAt = startedAt
        firstConfirmedAt = nil
        candidates.removeAll()
        navigationReferrers.removeAll()
        isLoading = true
        progressMessage = LocalizationService.shared.t("正在初始化解析器...")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                // The caller can be cancelled between entering the operation and installing its continuation.
                guard !Task.isCancelled else {
                    self.finish(with: .error("已取消"), resolveId: requestID)
                    return
                }
                self.timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(1, timeout))) } catch { return }
                    guard let self, self.resolveId == requestID else { return }
                    await self.completeCandidates(resolveId: requestID, timedOut: true)
                }
                self.setupWebView(rule: rule, resolveId: requestID)
                guard let sourceWebView = self.webView else { return }
                Task { @MainActor [weak self, weak sourceWebView] in
                    guard let self, let sourceWebView else { return }
                    let store = sourceWebView.configuration.websiteDataStore.httpCookieStore
                    for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
                        guard self.isCurrent(sourceWebView, requestID) else { return }
                        await store.setCookie(cookie)
                    }
                    guard self.isCurrent(sourceWebView, requestID) else { return }
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
                    request.allHTTPHeaderFields = Self.requestHeaders(for: url, rule: rule, pageURL: rule.baseURL)
                    sourceWebView.load(request)
                    self.addLog("开始解析 host=\(Self.safeHost(url))")
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.resolveId == requestID else { return }
                self.cancelAndCleanup()
            }
        }
    }

    func cancel() { cancelAndCleanup() }

    private func isCurrent(_ sourceWebView: WKWebView, _ requestID: Int) -> Bool {
        sourceWebView === webView && requestID == resolveId && continuation != nil
    }

    private func cancelAndCleanup() {
        resolveId += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        videoFoundTask?.cancel()
        videoFoundTask = nil
        cleanupWebView()
        candidates.removeAll()
        currentRule = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: .error(LocalizationService.shared.t("已取消")))
        }
        isLoading = false
    }

    private func setupWebView(rule: AnimeRule, resolveId: Int) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Each extraction owns a clean store. Late cookie work can never mutate the next extraction.
        dataStore = WKWebsiteDataStore.nonPersistent()
        config.websiteDataStore = dataStore
        let controller = WKUserContentController()
        controller.add(self, name: "VideoBridge")
        controller.add(self, name: "CaptchaBridge")
        config.userContentController = controller
        controller.addUserScript(WKUserScript(source: captchaDetectionScript(), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.networkInterceptorScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.videoScannerScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.lazyFrameScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        if rule.useLegacyParser == true {
            controller.addUserScript(WKUserScript(source: Self.legacyIframeParserScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = Self.effectiveUserAgent(rule: rule)
        view.navigationDelegate = self
        webView = view
        // Kazumi 同款基础拦截始终开启：广告文档/反调试脚本/图片不加载，
        // 广告视频从源头没有机会先于正片产生媒体证据。
        installContentBlockers(on: view, resolveId: resolveId)
    }

    /// 编译并挂载广告拦截规则。编译结果进程内缓存一次；挂载前校验代次，
    /// 迟到回调不得污染下一次解析的 WebView。编译失败退回无拦截，不阻塞解析。
    private func installContentBlockers(on view: WKWebView, resolveId: Int) {
        if let cached = Self.compiledBlockers {
            view.configuration.userContentController.add(cached)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "WaifuXAnimeExtractionBlockers",
            encodedContentRuleList: Self.contentBlockerRulesJSON
        ) { [weak self, weak view] list, error in
            Task { @MainActor in
                guard let list else {
                    Self.logger.notice("content_blockers_compile_failed error=\(error?.localizedDescription ?? "unknown", privacy: .public)")
                    return
                }
                Self.compiledBlockers = list
                guard let self, let view, view === self.webView, self.resolveId == resolveId else { return }
                view.configuration.userContentController.add(list)
                self.addLog("广告拦截规则已挂载")
            }
        }
    }

    private static var compiledBlockers: WKContentRuleList?

    /// Kazumi video_webview_apple_impl contentBlockers 等价 JSON：
    /// 拦全部图片、devtools-detector.js、googleads/googlesyndication/prestrain(.html|%2Ehtml)/
    /// adtrafficquality 文档，以及常见广告网络域名的全部请求。
    static let contentBlockerRulesJSON: String = {
        var rules: [[String: Any]] = []
        func block(_ filter: String, types: [String]? = nil) {
            var trigger: [String: Any] = ["url-filter": filter]
            if let types { trigger["resource-type"] = types }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        block(#"^https?://.+?devtools-detector\.js"#, types: ["script"])
        block(".*", types: ["image"])
        block(#"^https?://.+?googleads"#, types: ["document"])
        block(#"^https?://.+?googlesyndication\.com"#, types: ["document"])
        block(#"^https?://.+?prestrain\.html"#, types: ["document"])
        block(#"^https?://.+?prestrain%2Ehtml"#, types: ["document"])
        block(#"^https?://.+?adtrafficquality"#, types: ["document"])
        // 广告网络的媒体/脚本/XHR 也一并拦截，广告视频从源头不产生候选。
        let adHosts = ["googlesyndication\\.com", "doubleclick\\.net", "googleadservices\\.com",
                       "adservice\\.google\\.com", "adtrafficquality\\.google", "googletagservices\\.com",
                       "adsystem\\.com", "adnxs\\.com", "adsrvr\\.org", "taboola\\.com", "outbrain\\.com",
                       "popads\\.net", "popcash\\.net", "propellerads\\.com", "exoclick\\.com",
                       "juicyads\\.com", "trafficjunky\\.com", "hilltopads\\.com", "adcash\\.com",
                       "magsrv\\.com", "mnaspm\\.com", "bbrdbr\\.com"]
        for host in adHosts {
            block(#"^https?://([a-z0-9-]+\.)*"# + host)
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    private func captchaDetectionScript() -> String {
        let config = currentRule?.antiCrawlerConfig
        let settings: [String: Any] = ["enabled": config?.enabled ?? false,
                                       "type": config?.captchaDetectType ?? 0,
                                       "value": config?.captchaDetectValue ?? "",
                                       "image": config?.captchaImage ?? "",
                                       "button": config?.captchaButton ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "false" }
        return Self.captchaDetectorScriptSource + "\nwindow.__kazumiDetectCaptcha(" + json + ")"
    }

    private func detectCaptcha(in sourceWebView: WKWebView, resolveId: Int) {
        let source = captchaDetectionScript()
        sourceWebView.evaluateJavaScript(source) { [weak self, weak sourceWebView] value, _ in
            Task { @MainActor in
                guard let self, let sourceWebView, self.isCurrent(sourceWebView, resolveId),
                      value as? Bool == true,
                      self.candidates.values.allSatisfy({ $0.confidence < 75 }) else { return }
                self.finish(with: .captcha, resolveId: resolveId)
            }
        }
    }

    private func receive(_ payload: [String: Any], frameURL: URL?) {
        var payload = payload
        // legacy 原始 iframe src：在 Swift 侧提取 query 里的媒体直链（Kazumi decodeVideoSource），
        // 提取不到就丢弃——iframe 文档本身永远不是媒体候选。
        if payload["sourceKind"] as? String == "legacy-iframe-raw" {
            guard currentRule?.useLegacyParser == true,
                  let raw = payload["url"] as? String,
                  let media = AnimeMediaCandidate.legacyEmbeddedMediaURL(raw) else { return }
            payload["url"] = media
            payload["sourceKind"] = "legacy-iframe"
            payload["format"] = ""
        }
        guard let candidate = AnimeMediaCandidate.decode(payload, fallbackFrame: frameURL, pageURL: currentPageURL) else { return }
        let key = candidate.url.absoluteString
        if let existing = candidates[key], existing.confidence >= candidate.confidence { return }
        // Bound untrusted page output without letting early weak hints crowd out real media.
        if candidates.count >= 64, candidates[key] == nil {
            guard let weakest = candidates.min(by: { $0.value.confidence < $1.value.confidence }),
                  candidate.confidence > weakest.value.confidence else { return }
            candidates.removeValue(forKey: weakest.key)
        }
        candidates[key] = candidate
        lastImprovementAt = Date()
        // legacy iframe 直链与响应级证据同级：足以开启收敛窗口（Kazumi 对这类站点
        // 甚至首命中即播；这里保留短收敛窗防嵌套播放器的更优候选迟到）。
        if candidate.confidence >= 70, firstConfirmedAt == nil { firstConfirmedAt = Date() }
        progressMessage = LocalizationService.shared.t("已发现媒体，正在确认播放地址...")
        addLog("媒体候选 host=\(Self.safeHost(candidate.url)) format=\(candidate.format) evidence=\(candidate.sourceKind) confidence=\(candidate.confidence)")
        startCollectionWindow()
        if let frameURL { probeDirectMXdmHLS(candidate, frameURL: frameURL) }
    }

    /// MXdm 已验证站点/CDN 对的窄路径快速恢复（保留原行为，通用探测在预检阶段做）。
    private func probeDirectMXdmHLS(_ candidate: AnimeMediaCandidate, frameURL: URL) {
        guard allowsDirectMXdmHLS, directHLSProbe == nil, let rule = currentRule,
              candidate.sourceKind == "network-request",
              MXdmDirectHLS.eligible(candidate.url, page: frameURL.absoluteString, ruleID: rule.id),
              MXdmDirectHLS.eligible(candidate.url, page: currentPageURL, ruleID: rule.id) else { return }
        let id = resolveId
        let headers = Self.requestHeaders(for: candidate.url, rule: rule, pageURL: frameURL.absoluteString, userAgent: candidate.userAgent)
        directHLSProbe = Task { [weak self] in
            guard await MXdmDirectHLS.canRecover(candidate.url, headers: headers), !Task.isCancelled,
                  let self, self.resolveId == id, self.continuation != nil else { return }
            var source = VideoSource(quality: Self.quality(url: candidate.url, format: "m3u8"), url: candidate.url.absoluteString, type: "m3u8", label: nil)
            source.httpHeaders = headers
            source.usesDirectHLSRelay = true
            self.addLog("系统代理拒绝 MXdm 媒体；已验证直连播放列表")
            self.finish(with: .success([source]), resolveId: id)
        }
    }

    private func startCollectionWindow() {
        guard videoFoundTask == nil else { return }
        let requestID = resolveId
        videoFoundTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let self, self.resolveId == requestID, self.continuation != nil else { return }
                // Weak URL hints never end collection. A response or decoded media element earns
                // a settling window, with at least four seconds for nested players and a finite budget.
                guard let firstConfirmedAt = self.firstConfirmedAt else { continue }
                let now = Date()
                if (now.timeIntervalSince(self.startedAt) >= 4 && now.timeIntervalSince(self.lastImprovementAt) >= 1.6)
                    || now.timeIntervalSince(firstConfirmedAt) >= 10 {
                    await self.completeCandidates(resolveId: requestID, timedOut: false)
                    return
                }
            }
        }
    }

    private func completeCandidates(resolveId: Int, timedOut: Bool) async {
        guard resolveId == self.resolveId, continuation != nil else { return }
        // Request-only hints are insufficient: a failed request or HTML response cannot be played.
        // legacy iframe 直链（70）参与收敛：这类站点没有响应级证据，拒绝它等于全站不可播。
        let ranked = candidates.values.filter { $0.confidence >= 70 }.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            let lhsRank = $0.format == "m3u8" ? 0 : ($0.format == "mp4" ? 1 : 2)
            let rhsRank = $1.format == "m3u8" ? 0 : ($1.format == "mp4" ? 1 : 2)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return $0.url.absoluteString < $1.url.absoluteString
        }
        guard !ranked.isEmpty else {
            if timedOut { finish(with: .timeout, resolveId: resolveId) }
            return
        }
        if let sourceWebView = webView {
            let cookies = await sourceWebView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard isCurrent(sourceWebView, resolveId) else { return }
            // Only persist cookies that WebKit actually scoped to a discovered media URL.
            for cookie in cookies where ranked.contains(where: { Self.cookie(cookie, matches: $0.url) }) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
        guard resolveId == self.resolveId, continuation != nil, let rule = currentRule else { return }
        let sources = ranked.map { candidate in
            var source = VideoSource(quality: Self.quality(url: candidate.url, format: candidate.format), url: candidate.url.absoluteString, type: candidate.format, label: nil)
            let originPage = Self.nonempty(candidate.referrer) ?? Self.nonempty(candidate.frameURL) ?? candidate.pageURL
            source.httpHeaders = Self.requestHeaders(for: candidate.url, rule: rule, pageURL: originPage, userAgent: candidate.userAgent)
            return source
        }
        finish(with: .success(sources), resolveId: resolveId)
    }

    static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased(), cookie.expiresDate.map({ $0 > Date() }) ?? true,
              !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
        let domain = cookie.domain.lowercased()
        let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bareDomain || (domain.hasPrefix(".") && host.hasSuffix("." + bareDomain)) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
    }

    private static func quality(url: URL, format: String) -> String {
        if ["m3u8", "mpd"].contains(format) { return "Auto" }
        let path = url.path.lowercased()
        if path.contains("1080") { return "1080P" }
        if path.contains("720") { return "720P" }
        if path.contains("480") { return "480P" }
        return format.uppercased()
    }

    private static func safeHost(_ url: URL) -> String { url.host ?? "unknown" }

    private func addLog(_ message: String) {
        // Callers supply only fixed text, formats and host names; never page-provided logs or URLs.
        logMessages.append(message)
        if logMessages.count > 100 { logMessages.removeFirst(logMessages.count - 100) }
        Self.logger.info("\(message, privacy: .public)")
    }

    private func finish(with result: VideoExtractionResult, resolveId: Int) {
        guard resolveId == self.resolveId, let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        videoFoundTask?.cancel()
        videoFoundTask = nil
        isLoading = false
        switch result {
        case .success(let sources): progressMessage = "找到 \(sources.count) 个视频源"
        case .error(let message): progressMessage = message
        case .captcha: progressMessage = LocalizationService.shared.t("需要验证码验证")
        case .timeout: progressMessage = LocalizationService.shared.t("视频解析超时")
        }
        cleanupWebView()
        continuation.resume(returning: result)
    }

    private func cleanupWebView() {
        directHLSProbe?.cancel()
        directHLSProbe = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.removeAllContentRuleLists()
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
    }
}

// MARK: - Frame-local bridge scripts

extension AnimeVideoExtractor {
    static let captchaDetectorScriptSource = #"""
    (function() {
        'use strict';
        window.__kazumiDetectCaptcha = function(config) {
            function visible(node) {
                if (!node || node.hidden || node.getAttribute && node.getAttribute('aria-hidden') === 'true') return false;
                try {
                    const style = node.ownerDocument.defaultView.getComputedStyle(node);
                    return style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) !== 0 && node.getClientRects().length > 0;
                } catch (_) { return false; }
            }
            function xpath(doc, expression) {
                if (!expression || expression.length > 4096) return false;
                try { return !!doc.evaluate(expression, doc, null, 9, null).singleNodeValue; } catch (_) { return false; }
            }
            function detect(doc, depth) {
                if (!doc || depth > 8) return false;
                const html = (doc.documentElement && doc.documentElement.outerHTML || '').slice(0, 262144);
                const body = (doc.body && doc.body.innerText || '').slice(0, 32768);
                const title = (doc.title || '').toLowerCase();
                const value = String(config.value || '').trim();
                let matched = false;
                if (config.enabled) {
                    if (value && value.length <= 4096) {
                        if (config.type === 1) matched = xpath(doc, value);
                        else if (config.type === 2) matched = html.includes(value);
                        else if (config.type === 3) { try { matched = new RegExp(value, 's').test(html); } catch (_) {} }
                    } else if (!value) matched = xpath(doc, config.image) || xpath(doc, config.button);
                }
                // Generic detection requires a visible challenge control, or a short dedicated
                // verification page with explicit wording. Mere scripts/words in a video page do not count.
                if (!matched) {
                    const controls = doc.querySelectorAll('input[name="captcha"], input[name="verifycode"], iframe[src*="recaptcha/api2/bframe"], iframe[src*="hcaptcha.com/captcha"], .cf-turnstile, #challenge-stage');
                    matched = Array.from(controls).some(visible);
                    const titleChallenge = /^(captcha|security verification|verify you are human|安全验证|人机验证|验证码)$/.test(title.trim());
                    const bodyChallenge = /verify (that )?you are human|complete the (captcha|security check)|请输入.{0,8}验证码|请完成.{0,8}(人机|安全)验证/i.test(body);
                    if (!matched && body.length < 6000 && titleChallenge && bodyChallenge && !doc.querySelector('video')) matched = true;
                }
                if (matched) return true;
                for (const frame of doc.querySelectorAll('iframe')) {
                    try { if (frame.contentDocument && detect(frame.contentDocument, depth + 1)) return true; } catch (_) {}
                }
                return false;
            }
            const result = detect(document, 0);
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.CaptchaBridge;
            if (result && bridge) bridge.postMessage(true);
            return result;
        };
    })();
    """#

    // A bounded prefix is enough to recognize HLS. Never clone/text() complete video responses.
    static let networkInterceptorScriptSource = #"""
    (function() {
        'use strict';
        if (window.__kazumiNetworkInterceptorInstalled) return;
        window.__kazumiNetworkInterceptorInstalled = true;
        const MAX_PREFIX = 4096;
        const emitted = new Set();
        function absolute(raw) {
            try {
                const value = typeof raw === 'string' ? raw : raw && raw.url;
                const url = new URL(value, document.baseURI);
                return /^(https?):$/.test(url.protocol) ? url : null;
            } catch (_) { return null; }
        }
        function pathFormat(url) {
            const match = url.pathname.match(/\.(m3u8|mp4|m4v|mov|webm|mkv|flv|mpd)$/i);
            return match ? (match[1].toLowerCase() === 'm4v' ? 'mp4' : match[1].toLowerCase()) : '';
        }
        function segment(url) { return /\.(ts|m4s|m4a|aac|vtt|key)$/i.test(url.pathname); }
        function mimeFormat(mime) {
            mime = (mime || '').split(';')[0].trim().toLowerCase();
            if (/^(application\/(vnd\.apple\.mpegurl|x-mpegurl)|audio\/(mpegurl|x-mpegurl))$/.test(mime)) return 'm3u8';
            if (mime === 'application/dash+xml') return 'mpd';
            return ({'video/mp4':'mp4','video/x-m4v':'mp4','video/quicktime':'mov','video/webm':'webm','video/x-matroska':'mkv','video/x-flv':'flv'})[mime] || '';
        }
        function send(raw, kind, format, evidence, status, contentType, ownerDocument) {
            const doc = ownerDocument || document;
            let url;
            try { url = new URL(typeof raw === 'string' ? raw : raw.url, doc.baseURI); } catch (_) { return; }
            if (!/^https?:$/.test(url.protocol) || segment(url)) return;
            // 已知广告网络宿主：与 Swift 侧 isAdHost 同口径，双保险。
            if (/(^|\.)(googlesyndication\.com|doubleclick\.net|googleadservices\.com|adservice\.google\.com|adtrafficquality\.google|googletagservices\.com|adsystem\.com|adnxs\.com|adsrvr\.org|taboola\.com|outbrain\.com|popads\.net|popcash\.net|propellerads\.com|exoclick\.com|juicyads\.com|trafficjunky\.com|hilltopads\.com|adcash\.com|magsrv\.com|mnaspm\.com|bbrdbr\.com)$/i.test(url.hostname)) return;
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.VideoBridge;
            if (!bridge) return;
            if ((kind === 'media-hint' || kind === 'network-request') && !pathFormat(url)) return;
            const identity = kind + '|' + url.href + '|' + (evidence || '') + '|' + (status || 0);
            if (emitted.has(identity)) return;
            if (emitted.size >= 192) {
                if (kind === 'media-hint' || kind === 'network-request') return;
                emitted.clear();
            }
            emitted.add(identity);
            const frameURL = doc.location ? doc.location.href : doc.baseURI;
            let pageURL = frameURL;
            try { pageURL = window.top.location.href; } catch (_) {}
            bridge.postMessage({url:url.href, format:format || pathFormat(url), sourceKind:kind,
                frameURL:frameURL, pageURL:pageURL, referrer:frameURL, documentReferrer:doc.referrer || '',
                userAgent:navigator.userAgent, evidence:evidence || '', status:status || 0, contentType:contentType || ''});
        }
        window.__kazumiMediaBridge = {send:send, pathFormat:pathFormat};
        async function prefix(response) {
            if (!response.body || !response.body.getReader) return '';
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let text = '', count = 0;
            try {
                while (count < MAX_PREFIX) {
                    const chunk = await reader.read();
                    if (chunk.done) break;
                    const part = chunk.value.subarray(0, MAX_PREFIX - count);
                    count += part.length;
                    text += decoder.decode(part, {stream:true});
                    if (text.trimStart().startsWith('#EXTM3U') || /\S/.test(text) && !text.trimStart().startsWith('#')) break;
                }
            } finally { reader.cancel().catch(function() {}); }
            return text;
        }
        const originalFetch = window.fetch;
        if (originalFetch) window.fetch = function() {
            const args = arguments;
            const raw = args[0];
            const url = absolute(raw);
            if (url && !segment(url) && pathFormat(url)) send(url.href, 'network-request', pathFormat(url), 'path');
            return originalFetch.apply(this, args).then(function(response) {
                const finalURL = absolute(response.url || (url && url.href));
                if (!finalURL || segment(finalURL) || response.status < 200 || response.status > 299) return response;
                const mime = response.headers.get('content-type') || '';
                if (/text\/html|application\/xhtml|video\/mp2t/i.test(mime)) return response;
                const format = mimeFormat(mime);
                if (format) send(finalURL.href, 'fetch-response', format, 'mime', response.status, mime);
                else {
                    const length = Number(response.headers.get('content-length') || 0);
                    // Inspect text/unknown small responses; skip known binary video and oversized payloads.
                    if ((!length || length <= 1048576) && !/^video\//i.test(mime)) {
                        prefix(response.clone()).then(function(text) {
                            if (text.replace(/^\uFEFF/, '').trimStart().startsWith('#EXTM3U'))
                                send(finalURL.href, 'fetch-response', 'm3u8', 'hls-body', response.status, mime);
                            else if (pathFormat(finalURL) && !/^\s*</.test(text))
                                send(finalURL.href, 'fetch-response', pathFormat(finalURL), 'path', response.status, mime);
                        }).catch(function() {});
                    }
                }
                return response;
            });
        };
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, raw) {
            this.__kazumiURL = absolute(raw);
            const url = this.__kazumiURL;
            if (url && !segment(url) && pathFormat(url)) send(url.href, 'network-request', pathFormat(url), 'path');
            if (!this.__kazumiListener) {
                this.__kazumiListener = true;
                this.addEventListener('load', function() {
                    try {
                        const finalURL = absolute(this.responseURL || (this.__kazumiURL && this.__kazumiURL.href));
                        const mime = this.getResponseHeader('content-type') || '';
                        if (!finalURL || segment(finalURL) || this.status < 200 || this.status > 299 || /text\/html|application\/xhtml|video\/mp2t/i.test(mime)) return;
                        let text = '';
                        if (this.responseType === '' || this.responseType === 'text') text = this.responseText.slice(0, MAX_PREFIX);
                        const bodyHLS = text.replace(/^\uFEFF/, '').trimStart().startsWith('#EXTM3U');
                        const format = bodyHLS ? 'm3u8' : mimeFormat(mime) || (!/^\s*</.test(text) && pathFormat(finalURL));
                        if (format) send(finalURL.href, 'xhr-response', format, bodyHLS ? 'hls-body' : 'mime', this.status, mime);
                    } catch (_) {}
                });
            }
            return originalOpen.apply(this, arguments);
        };
        // Kazumi blobParser 同款：播放器用 Response.text() 读播放列表时（hls.js 常见路径），
        // 即使 URL 无扩展名、MIME 是 octet-stream，也能凭 #EXTM3U 正文确认媒体。
        // 只观察不克隆：text() 本来就要读完整个 body，这里只检查前缀。
        const responseText = window.Response && window.Response.prototype && window.Response.prototype.text;
        if (responseText) window.Response.prototype.text = function() {
            const response = this;
            return responseText.call(this).then(function(text) {
                try {
                    if (typeof text === 'string' && text.replace(/^\uFEFF/, '').trimStart().startsWith('#EXTM3U')) {
                        const finalURL = absolute(response.url);
                        if (finalURL && !segment(finalURL) && response.status >= 200 && response.status <= 299) {
                            const mime = (response.headers && response.headers.get('content-type')) || '';
                            if (!/text\/html|application\/xhtml/i.test(mime))
                                send(finalURL.href, 'fetch-response', 'm3u8', 'hls-body', response.status, mime);
                        }
                    }
                } catch (_) {}
                return text;
            });
        };
    })();
    """#

    /// Kazumi removeLazyLoading 同款：摘掉 iframe 的 lazy 属性，播放器框架立即加载。
    static let lazyFrameScriptSource = #"""
    (function() {
        'use strict';
        function removeLazyLoading(root) {
            try {
                (root || document).querySelectorAll('iframe[loading="lazy"]').forEach(function(frame) {
                    frame.removeAttribute('loading');
                });
            } catch (_) {}
        }
        function install() {
            removeLazyLoading(document);
            if (!document.documentElement) return;
            new MutationObserver(function(mutations) {
                for (const mutation of mutations) {
                    if (mutation.type === 'attributes') { removeLazyLoading(document); return; }
                    for (const node of mutation.addedNodes) {
                        if (node.nodeType !== 1) continue;
                        if (node.nodeName === 'IFRAME' && node.getAttribute('loading') === 'lazy') node.removeAttribute('loading');
                        else if (node.querySelectorAll) removeLazyLoading(node);
                    }
                }
            }).observe(document.documentElement, {childList: true, subtree: true, attributes: true, attributeFilter: ['loading']});
        }
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, {once: true});
        else install();
    })();
    """#

    /// Kazumi useLegacyParser 路径：扫 iframe src，把 query 参数里的 m3u8/mp4 直链
    /// 经 Swift 侧 legacyEmbeddedMediaURL 严格校验后作为 legacy-iframe 候选。
    /// 只在规则声明 useLegacyParser 时注入；原始 iframe 文档 URL 依旧被拒绝。
    static let legacyIframeParserScriptSource = #"""
    (function() {
        'use strict';
        if (window.__kazumiLegacyParserInstalled) return;
        window.__kazumiLegacyParserInstalled = true;
        const reported = new Set();
        function scan() {
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.VideoBridge;
            if (!bridge) return;
            document.querySelectorAll('iframe').forEach(function(frame) {
                const src = frame.getAttribute('src');
                if (!src || reported.has(src) || reported.size >= 64) return;
                reported.add(src);
                let frameURL = document.location ? document.location.href : document.baseURI;
                let pageURL = frameURL;
                try { pageURL = window.top.location.href; } catch (_) {}
                // 原样上报 iframe src；媒体 URL 的提取与校验在 Swift 侧完成。
                bridge.postMessage({url: src, sourceKind: 'legacy-iframe-raw', format: '',
                    frameURL: frameURL, pageURL: pageURL, referrer: frameURL,
                    userAgent: navigator.userAgent, evidence: 'iframe-query', status: 0, contentType: ''});
            });
        }
        function install() {
            scan();
            if (!document.documentElement) return;
            new MutationObserver(function() { scan(); }).observe(document.documentElement,
                {childList: true, subtree: true, attributes: true, attributeFilter: ['src']});
        }
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, {once: true});
        else install();
    })();
    """#

    static let videoScannerScriptSource = #"""
    (function() {
        'use strict';
        if (window.__kazumiVideoScannerInstalled) return;
        window.__kazumiVideoScannerInstalled = true;
        const watched = new WeakSet();
        function process(video) {
            const doc = video.ownerDocument || document;
            const bridge = window.__kazumiMediaBridge;
            if (!bridge) return;
            function report(raw, type, ready) {
                if (!raw || /^(blob:|data:)/i.test(raw)) return;
                bridge.send(raw, ready ? 'media-element' : 'media-hint', type || '', ready ? 'media-ready' : 'path', null, '', doc);
            }
            const selected = video.currentSrc || video.getAttribute('src');
            function isSelected(raw) {
                try { return new URL(raw, doc.baseURI).href === new URL(selected, doc.baseURI).href; } catch (_) { return false; }
            }
            report(selected, video.getAttribute('type'), video.readyState >= 1);
            report(video.getAttribute('src'), video.getAttribute('type'), video.readyState >= 1 && isSelected(video.getAttribute('src')));
            report(video.getAttribute('data-src'), video.getAttribute('type'), false);
            video.querySelectorAll('source').forEach(function(source) {
                const raw = source.getAttribute('src');
                report(raw, source.getAttribute('type'), video.readyState >= 1 && isSelected(raw));
            });
            if (!watched.has(video)) {
                watched.add(video);
                ['loadedmetadata','loadeddata','canplay'].forEach(function(event) { video.addEventListener(event, function() { process(video); }); });
            }
        }
        function scan(doc) {
            doc.querySelectorAll('video').forEach(process);
            // WKUserScript runs in cross-origin frames too; same-origin recursion only handles about:blank frames.
            doc.querySelectorAll('iframe').forEach(function(frame) {
                try { if (frame.contentDocument && frame.contentDocument !== doc) scan(frame.contentDocument); } catch (_) {}
            });
        }
        function install() {
            scan(document);
            if (!document.documentElement) return;
            new MutationObserver(function() { scan(document); }).observe(document.documentElement,
                {childList:true, subtree:true, attributes:true, attributeFilter:['src','data-src','type']});
        }
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, {once:true});
        else install();
    })();
    """#
}

extension AnimeVideoExtractor: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard let sourceWebView = message.webView, sourceWebView === self.webView,
                  self.continuation != nil else { return }
            if message.name == "CaptchaBridge", message.body as? Bool == true,
               self.candidates.values.allSatisfy({ $0.confidence < 75 }) {
                self.finish(with: .captcha, resolveId: self.resolveId)
            } else if message.name == "VideoBridge", let payload = message.body as? [String: Any] {
                self.receive(payload, frameURL: message.frameInfo.request.url)
            }
        }
    }
}

extension AnimeVideoExtractor: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            guard webView === self.webView, self.continuation != nil else { return }
            self.progressMessage = LocalizationService.shared.t("正在加载页面...")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard webView === self.webView, self.continuation != nil else { return }
            self.progressMessage = LocalizationService.shared.t("页面加载完成，扫描视频...")
            self.detectCaptcha(in: webView, resolveId: self.resolveId)
            // A muted play starts page-owned lazy media requests; no frame or overlay is captured here.
            webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => { v.muted = true; v.play().catch(() => {}); });", completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, continuation != nil else { decisionHandler(.cancel); return }
        if let url = navigationAction.request.url {
            let referrer = navigationAction.request.value(forHTTPHeaderField: "Referer")
                ?? navigationAction.sourceFrame.request.url?.absoluteString ?? currentPageURL
            if navigationReferrers.count < 128 { navigationReferrers[url.absoluteString] = referrer }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView, continuation != nil else { decisionHandler(.cancel); return }
        if let response = navigationResponse.response as? HTTPURLResponse, let url = response.url,
           let format = AnimeMediaCandidate.mimeFormat(response.mimeType ?? ""), (200...299).contains(response.statusCode) {
            let referrer = navigationReferrers[url.absoluteString] ?? webView.url?.absoluteString ?? currentPageURL
            receive(["url":url.absoluteString, "format":format, "sourceKind":"navigation-response", "evidence":"mime",
                     "status":response.statusCode, "contentType":response.mimeType ?? "", "frameURL":referrer,
                     "referrer":referrer, "userAgent":webView.customUserAgent ?? Self.defaultBrowserUserAgent], frameURL: webView.url)
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(webView, error: error)
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(webView, error: error)
    }

    nonisolated private func handleNavigationError(_ sourceWebView: WKWebView, error: Error) {
        Task { @MainActor in
            guard sourceWebView === self.webView, self.continuation != nil else { return }
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            let description = nsError.localizedDescription.lowercased()
            if description.contains("captcha") || description.contains("challenge") || description.contains("验证") {
                self.finish(with: .captcha, resolveId: self.resolveId)
            } else if self.candidates.values.allSatisfy({ $0.confidence < 75 }) {
                self.addLog("页面请求失败 domain=\(nsError.domain) code=\(nsError.code)")
                self.finish(with: .error("页面加载失败，请重试或切换线路"), resolveId: self.resolveId)
            }
        }
    }
}
