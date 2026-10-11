import Foundation
import WebKit

/// Wallsflow 的页面加载回退。WebKit 只在主线程使用；同一时刻只加载一个页面。
/// 会话 Cookie 可持久化，页面在每次成功、失败或取消后立即释放。
@MainActor
final class WallsflowWebFetcher: NSObject, WKNavigationDelegate {
    static let shared = WallsflowWebFetcher()

    private(set) var currentUserAgent: String?
    private var requestTail: Task<String, Error>?
    private var tailID: UUID?
    private var queuedRequests = 0
    private var webView: WKWebView?
    private var activeRequestID: UUID?
    private var navigation: WKNavigation?
    private var navigationReply: CheckedContinuation<Void, Error>?
    private var scriptReply: CheckedContinuation<String, Error>?
    private var requestError: Error?
    private var isTerminating = false
    private let challengeTimeout: TimeInterval = 30
    private let challengePageMarkers = ["just a moment", "请稍候", "請稍候", "正在執行安全驗證", "正在执行安全验证"]

    private override init() { super.init() }

    func fetchHTML(from url: URL) async throws -> String {
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
            return try await self.loadThroughWebView(url)
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
            let html = try await task.value
            try Task.checkCancellation()
            return html
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
        guard activeRequestID == id else { return }
        requestError = error
        let navigationReply = self.navigationReply
        let scriptReply = self.scriptReply
        self.navigationReply = nil
        self.scriptReply = nil
        navigationReply?.resume(throwing: error)
        scriptReply?.resume(throwing: error)
        webView?.stopLoading()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === self.navigation else { return }
        let reply = navigationReply
        navigationReply = nil
        reply?.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, navigation === self.navigation, let id = activeRequestID else { return }
        failRequest(id, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, navigation === self.navigation, let id = activeRequestID else { return }
        failRequest(id, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, let id = activeRequestID else { return }
        failRequest(id, error: URLError(.networkConnectionLost))
    }
}
