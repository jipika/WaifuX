import Foundation
import WebKit

/// Shared by the HTML, image and video paths. Never accept a challenge page as media.
enum WallsflowMediaPolicy {
    static func owns(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        return host == "wallsflow.com" || host.hasSuffix(".wallsflow.com")
    }

    static func applyingBrowserIdentity(to request: URLRequest, userAgent: String?) -> URLRequest {
        var request = request
        guard let url = request.url, owns(url) else { return request }
        let pageURL = request.value(forHTTPHeaderField: "Referer").flatMap(URL.init(string:))
        for key in (request.allHTTPHeaderFields ?? [:]).keys where key.lowercased().hasPrefix("sec-ch-ua") {
            request.setValue(nil, forHTTPHeaderField: key)
        }
        for (key, value) in WallsflowService.mediaRequestHeaders(for: url, pageURL: pageURL) ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            // WKWebView's Safari identity must not carry a contradictory Chromium hint.
            for key in (request.allHTTPHeaderFields ?? [:]).keys where key.lowercased().hasPrefix("sec-ch-ua") {
                request.setValue(nil, forHTTPHeaderField: key)
            }
        }
        return request
    }

    static func isMedia(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true } // JPEG
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return true } // PNG
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { return true }
        guard bytes.count >= 12 else { return false }
        if bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WEBP".utf8) { return true }
        // MP4 and AVIF/HEIF use an ISO base media file header.
        return bytes[4..<8].elementsEqual("ftyp".utf8)
    }

    static func accepts(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() != "challenge" else { return false }
        let mime = (response.mimeType ?? "").lowercased()
        return mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime == "application/octet-stream"
    }

    static var verificationRequired: URLError {
        URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey:
            "Wallsflow 媒体访问需要网站验证，暂时无法加载。请在网站确认可正常访问后重试。"])
    }
}

/// Wallsflow 的页面加载回退。WebKit 只在主线程使用；同一时刻只加载一个页面。
/// 会话 Cookie 可持久化，页面在每次成功、失败或取消后立即释放。
@MainActor
final class WallsflowWebFetcher: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    static let shared = WallsflowWebFetcher()

    private(set) var currentUserAgent: String?
    private enum Result: Sendable {
        case html(String)
        case media(Data)
    }
    private var requestTail: Task<Result, Error>?
    private var tailID: UUID?
    private var queuedRequests = 0
    private var webView: WKWebView?
    private var activeRequestID: UUID?
    private var navigation: WKNavigation?
    private var navigationReply: CheckedContinuation<Void, Error>?
    private var scriptReply: CheckedContinuation<String, Error>?
    private var mediaReply: CheckedContinuation<Void, Error>?
    private var mediaDownload: WKDownload?
    private var mediaDestination: URL?
    private var mediaTimeout: Task<Void, Never>?
    private var loadingMedia = false
    private var mediaDownloadRequested = false
    private var mediaRetryAfter: [String: Date] = [:]
    private var requestError: Error?
    private var isTerminating = false
    private let challengeTimeout: TimeInterval = 30
    private let challengePageMarkers = ["just a moment", "请稍候", "請稍候", "正在執行安全驗證", "正在执行安全验证"]

    private override init() { super.init() }

    func fetchHTML(from url: URL) async throws -> String {
        guard case .html(let html) = try await enqueue({
            .html(try await self.loadThroughWebView(url))
        }) else { throw URLError(.badServerResponse) }
        return html
    }

    func fetchMediaData(for request: URLRequest) async throws -> Data {
        guard let url = request.url, WallsflowMediaPolicy.owns(url), let host = url.host?.lowercased() else {
            throw URLError(.unsupportedURL)
        }
        guard case .media(let data) = try await enqueue({
            // A grid of blocked covers must not create one challenge WebView per image.
            guard Date() >= (self.mediaRetryAfter[host] ?? .distantPast) else { throw WallsflowMediaPolicy.verificationRequired }
            do {
                let data = try await self.loadMediaThroughWebView(request)
                self.mediaRetryAfter.removeValue(forKey: host)
                return .media(data)
            } catch {
                if (error as? URLError)?.code == .userAuthenticationRequired {
                    self.mediaRetryAfter[host] = Date().addingTimeInterval(30)
                }
                throw error
            }
        }) else { throw URLError(.badServerResponse) }
        return data
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        guard !isTerminating else { throw CancellationError() }
        guard !BackgroundRuntimeRole.isIsolatedTest else {
            throw WallsflowError.parseFailed("隔离测试不启用 WebView 页面回退")
        }
        guard queuedRequests < 8 else {
            throw WallsflowError.parseFailed("页面加载请求过多，请稍后重试")
        }
        let previous = requestTail
        let id = UUID()
        queuedRequests += 1
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        requestTail = task
        tailID = id
        defer {
            queuedRequests -= 1
            if tailID == id {
                requestTail = nil
                tailID = nil
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    func warmUp() async throws {
        _ = try await fetchHTML(from: URL(string: WallsflowService.siteOrigin)!)
    }

    func prepareForProcessTermination() {
        isTerminating = true
        requestTail?.cancel()
        if let id = activeRequestID { failRequest(id, error: CancellationError()) }
    }

    private func loadMediaThroughWebView(_ originalRequest: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        guard !isTerminating else { throw CancellationError() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        view.isHidden = true
        view.navigationDelegate = self
        webView = view
        loadingMedia = true
        let id = UUID()
        activeRequestID = id
        requestError = nil
        mediaDestination = FileManager.default.temporaryDirectory.appendingPathComponent("waifux-wallsflow-\(id.uuidString)")
        armMediaTimeout(id, seconds: challengeTimeout)
        defer {
            mediaTimeout?.cancel()
            mediaTimeout = nil
            view.navigationDelegate = nil
            view.stopLoading()
            let destination = mediaDestination
            if let download = mediaDownload {
                download.delegate = nil
                download.cancel { _ in
                    if let destination { try? FileManager.default.removeItem(at: destination) }
                }
            } else if let destination {
                try? FileManager.default.removeItem(at: destination)
            }
            mediaDownload = nil
            mediaDestination = nil
            mediaReply = nil
            loadingMedia = false
            mediaDownloadRequested = false
            webView = nil
            navigation = nil
            activeRequestID = nil
            requestError = nil
        }
        return try await withTaskCancellationHandler {
            let userAgent = try await evaluateString("navigator.userAgent", in: view, id: id)
            var request = WallsflowMediaPolicy.applyingBrowserIdentity(to: originalRequest, userAgent: userAgent)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            try checkRequest()
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                mediaReply = reply
                navigation = view.load(request)
                if navigation == nil { failRequest(id, error: URLError(.cannotLoadFromNetwork)) }
            }
            try checkRequest()
            guard let destination = mediaDestination else { throw URLError(.badServerResponse) }
            let data = try Data(contentsOf: destination, options: [.mappedIfSafe])
            guard WallsflowMediaPolicy.isMedia(data) else { throw WallsflowMediaPolicy.verificationRequired }
            try await syncCookies(in: view, id: id)
            currentUserAgent = userAgent
            try checkRequest()
            return data
        } onCancel: { [weak self] in
            Task { @MainActor in self?.failRequest(id, error: CancellationError()) }
        }
    }

    private func armMediaTimeout(_ id: UUID, seconds: TimeInterval) {
        mediaTimeout?.cancel()
        mediaTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard let self else { return }
            self.failRequest(id, error: self.mediaDownload == nil
                             ? WallsflowMediaPolicy.verificationRequired : URLError(.timedOut))
        }
    }

    private func loadThroughWebView(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        guard !isTerminating else { throw CancellationError() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        view.isHidden = true
        view.navigationDelegate = self
        webView = view
        let id = UUID()
        activeRequestID = id
        requestError = nil
        let timeout = Task { [weak self, challengeTimeout] in
            do { try await Task.sleep(for: .seconds(challengeTimeout)) }
            catch { return }
            self?.failRequest(id, error: URLError(.timedOut))
        }
        defer {
            timeout.cancel()
            view.navigationDelegate = nil
            view.stopLoading()
            webView = nil
            navigation = nil
            activeRequestID = nil
            requestError = nil
        }
        return try await withTaskCancellationHandler {
            try checkRequest()
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                // Install the continuation before load: even an immediate
                // failure must complete exactly once.
                navigationReply = reply
                navigation = view.load(URLRequest(url: url))
                if navigation == nil { failRequest(id, error: URLError(.cannotLoadFromNetwork)) }
            }
            while true {
                try checkRequest()
                let title = try await evaluateString("document.title", in: view, id: id)
                let challenged = challengePageMarkers.contains { title.localizedCaseInsensitiveContains($0) }
                let bodyLength = Int(try await evaluateString(
                    "String(document.body ? document.body.innerText.length : 0)", in: view, id: id
                )) ?? 0
                if !challenged, bodyLength >= 400 {
                    let html = try await evaluateString("document.documentElement.outerHTML", in: view, id: id)
                    guard !html.isEmpty else { throw WallsflowError.parseFailed("WebView 返回了空 HTML") }
                    currentUserAgent = try await evaluateString("navigator.userAgent", in: view, id: id)
                    try await syncCookies(in: view, id: id)
                    try checkRequest()
                    return html
                }
                try await Task.sleep(for: .milliseconds(800))
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.failRequest(id, error: CancellationError()) }
        }
    }

    private func checkRequest() throws {
        try Task.checkCancellation()
        guard !isTerminating else { throw CancellationError() }
        if let requestError { throw requestError }
    }

    private func evaluateString(_ script: String, in view: WKWebView, id: UUID) async throws -> String {
        try checkRequest()
        return try await withCheckedThrowingContinuation { reply in
            scriptReply = reply
            view.evaluateJavaScript(script) { [weak self] value, error in
                guard let self, self.activeRequestID == id, let reply = self.scriptReply else { return }
                self.scriptReply = nil
                if let error { reply.resume(throwing: error) }
                else { reply.resume(returning: value as? String ?? "") }
            }
        }
    }

    private func syncCookies(in view: WKWebView, id: UUID) async throws {
        try checkRequest()
        let _: String = try await withCheckedThrowingContinuation { reply in
            scriptReply = reply
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, self.activeRequestID == id, let reply = self.scriptReply else { return }
                self.scriptReply = nil
                for cookie in cookies {
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if domain == "wallsflow.com" || domain.hasSuffix(".wallsflow.com") {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                }
                reply.resume(returning: "")
            }
        }
    }

    private func failRequest(_ id: UUID, error: Error) {
        guard activeRequestID == id, requestError == nil else { return }
        requestError = error
        let navigationReply = self.navigationReply
        let scriptReply = self.scriptReply
        let mediaReply = self.mediaReply
        self.navigationReply = nil
        self.scriptReply = nil
        self.mediaReply = nil
        navigationReply?.resume(throwing: error)
        scriptReply?.resume(throwing: error)
        mediaReply?.resume(throwing: error)
        webView?.stopLoading()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView, loadingMedia, navigationResponse.isForMainFrame,
              let id = activeRequestID else {
            decisionHandler(.allow)
            return
        }
        let response = navigationResponse.response
        if WallsflowMediaPolicy.accepts(response) {
            // Download before WebKit creates an image document or a video player.
            mediaDownloadRequested = true
            decisionHandler(.download)
        } else if let http = response as? HTTPURLResponse,
                  http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" {
            // Use the site's normal browser flow; interactive verification can time out.
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            let missing = (response as? HTTPURLResponse)?.statusCode == 404
            failRequest(id, error: missing ? URLError(.fileDoesNotExist) : WallsflowMediaPolicy.verificationRequired)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard webView === self.webView, loadingMedia, let id = activeRequestID, requestError == nil else {
            download.cancel { _ in }
            return
        }
        mediaDownload = download
        download.delegate = self
        armMediaTimeout(id, seconds: 900)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard download === mediaDownload, requestError == nil, WallsflowMediaPolicy.accepts(response) else {
            completionHandler(nil)
            if download === mediaDownload, let id = activeRequestID {
                failRequest(id, error: WallsflowMediaPolicy.verificationRequired)
            }
            return
        }
        completionHandler(mediaDestination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === mediaDownload else { return }
        let reply = mediaReply
        mediaReply = nil
        // The file is complete; the request's defer removes it after mapping the bytes.
        download.delegate = nil
        mediaDownload = nil
        reply?.resume()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard download === mediaDownload, let id = activeRequestID else { return }
        failRequest(id, error: error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === self.navigation else { return }
        let reply = navigationReply
        navigationReply = nil
        reply?.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Conversion can cancel navigation before didBecomeDownload arrives.
        // Once converted, failure/completion belongs to WKDownloadDelegate.
        if webView === self.webView, loadingMedia, mediaDownloadRequested { return }
        guard webView === self.webView, navigation === self.navigation, let id = activeRequestID else { return }
        failRequest(id, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, loadingMedia, mediaDownloadRequested { return }
        guard webView === self.webView, navigation === self.navigation, let id = activeRequestID else { return }
        failRequest(id, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, let id = activeRequestID else { return }
        failRequest(id, error: URLError(.networkConnectionLost))
    }
}
