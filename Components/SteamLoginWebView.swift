import SwiftUI
import WebKit

// MARK: - Steam Login WebView
/// 基于 WKWebView 的 Steam 登录视图
/// 打开 Steam OpenID 登录页面，用户登录后获取 Session Cookie
struct SteamLoginWebView: NSViewRepresentable {
    @Binding var isLoggedIn: Bool
    @Binding var steamID: String
    @Binding var isLoading: Bool
    @Binding var subscriptionHTMLRequestID: Int
    var onLoginSuccess: ((String) -> Void)?
    var onSubscriptionsHTML: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // 加载 Steam 登录页面
        let loginURL = URL(string: "https://steamcommunity.com/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions")!
        webView.load(URLRequest(url: loginURL))

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard subscriptionHTMLRequestID > 0,
              context.coordinator.lastHandledSubscriptionHTMLRequestID != subscriptionHTMLRequestID else {
            return
        }

        context.coordinator.lastHandledSubscriptionHTMLRequestID = subscriptionHTMLRequestID
        context.coordinator.loadSubscriptionsPageAndCaptureHTML(in: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SteamLoginWebView
        private var hasDetectedLogin = false
        fileprivate var lastHandledSubscriptionHTMLRequestID = 0
        private var shouldCaptureSubscriptionsHTML = false

        init(_ parent: SteamLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }

            // Steam's login cookies are HttpOnly, so document.cookie often cannot
            // see them. Check the WebKit cookie store first; it works when the
            // page is already logged in before the sheet opens.
            extractSteamIDFromCookies(webView: webView)
            if shouldCaptureSubscriptionsHTML {
                captureSubscriptionsHTML(from: webView)
            }

            // 检查当前 URL 是否包含订阅页面
            if let url = webView.url {
                let urlString = url.absoluteString

                // 检测是否在订阅页面（已登录状态）
                if urlString.contains("myworkshopfiles") && urlString.contains("browsefilter=mysubscriptions") {
                    // 尝试从页面提取 SteamID
                    webView.evaluateJavaScript("document.body.innerHTML") { result, error in
                        if let html = result as? String {
                            self.extractSteamIDFromPage(html, webView: webView)
                        }
                    }
                }

                // 检测 OpenID 回调
                if urlString.contains("openid.claimed_id") || urlString.contains("openid.identity") {
                    // 登录成功，提取 SteamID
                    self.extractSteamIDFromOpenID(url: url, webView: webView)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            print("[SteamLogin] Navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            print("[SteamLogin] Provisional navigation failed: \(error.localizedDescription)")
        }

        // MARK: - SteamID Extraction

        private func extractSteamIDFromPage(_ html: String, webView: WKWebView) {
            // 从 HTML 中提取 SteamID
            // 常见模式：steamid="76561198000000000" 或 profile/steamid
            let patterns = [
                "steamid=\"(\\d{17})\"",
                "\"steamid\":\"(\\d{17})\"",
                "profile/(\\d{17})",
                "\"steamid64\":\"(\\d{17})\""
            ]

            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                    let steamID = String(html[Range(match.range(at: 1), in: html)!])
                    completeLogin(with: steamID)
                    return
                }
            }

            // 如果无法提取，尝试从 Cookie 获取
            extractSteamIDFromCookies(webView: webView)
        }

        private func extractSteamIDFromOpenID(url: URL, webView: WKWebView) {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                for item in queryItems {
                    if item.name == "openid.identity" || item.name == "openid.claimed_id" {
                        if let value = item.value {
                            // OpenID identity 格式：https://steamcommunity.com/openid/id/76561198000000000
                            let components = value.components(separatedBy: "/")
                            if let steamID = components.last, steamID.count == 17, steamID.allSatisfy(\.isNumber) {
                                completeLogin(with: steamID)
                                return
                            }
                        }
                    }
                }
            }

            // 如果 OpenID 解析失败，尝试从页面提取
            webView.evaluateJavaScript("document.body.innerHTML") { result, error in
                if let html = result as? String {
                    self.extractSteamIDFromPage(html, webView: webView)
                }
            }
        }

        private func extractSteamIDFromCookies(webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard let cookie = cookies.first(where: { cookie in
                    cookie.name == "steamLoginSecure" &&
                    cookie.domain.contains("steamcommunity.com")
                }) else {
                    return
                }

                if let steamID = self.steamIDFromSteamLoginSecureCookie(cookie.value) {
                    self.completeLogin(with: steamID)
                } else {
                    DispatchQueue.main.async {
                        self.parent.isLoggedIn = true
                    }
                }
            }
        }

        fileprivate func loadSubscriptionsPageAndCaptureHTML(in webView: WKWebView) {
            shouldCaptureSubscriptionsHTML = true
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }

            let url = subscriptionsURL()
            if let currentURL = webView.url,
               currentURL.absoluteString == url.absoluteString {
                webView.reload()
            } else {
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
            }
        }

        private func subscriptionsURL() -> URL {
            let trimmedSteamID = parent.steamID.trimmingCharacters(in: .whitespacesAndNewlines)
            let basePath: String
            if trimmedSteamID.count == 17, trimmedSteamID.allSatisfy(\.isNumber) {
                basePath = "/profiles/\(trimmedSteamID)/myworkshopfiles/"
            } else {
                basePath = "/myworkshopfiles/"
            }

            var components = URLComponents(string: "https://steamcommunity.com\(basePath)")!
            components.queryItems = [
                URLQueryItem(name: "appid", value: "431960"),
                URLQueryItem(name: "browsefilter", value: "mysubscriptions"),
                URLQueryItem(name: "browsesort", value: "mysubscriptions"),
                URLQueryItem(name: "view", value: "imagewall"),
                URLQueryItem(name: "numperpage", value: "30")
            ]
            return components.url!
        }

        private func captureSubscriptionsHTML(from webView: WKWebView, attempt: Int = 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let script = """
                (() => {
                  const html = document.documentElement.outerHTML;
                  const ids = new Set();
                  document.querySelectorAll('[id^="Subscription"]').forEach((node) => {
                    const match = String(node.id || '').match(/^Subscription(\\d+)/);
                    if (match) ids.add(match[1]);
                  });
                  document.querySelectorAll('a[href*="sharedfiles/filedetails/?id="], a[href*="filedetails/?id="]').forEach((node) => {
                    try {
                      const url = new URL(node.href);
                      const id = url.searchParams.get('id');
                      if (id) ids.add(id);
                    } catch (_) {}
                  });
                  return {
                    url: location.href,
                    title: document.title,
                    itemCount: ids.size,
                    html
                  };
                })()
                """
                webView.evaluateJavaScript(script) { result, _ in
                    let payload = result as? [String: Any]
                    let itemCount = payload?["itemCount"] as? Int ?? 0
                    let html = payload?["html"] as? String
                    let url = payload?["url"] as? String ?? webView.url?.absoluteString ?? ""
                    let title = payload?["title"] as? String ?? ""

                    if itemCount == 0, attempt < 8 {
                        print("[SteamLogin] Waiting for subscription items, attempt=\(attempt + 1), url=\(url), title=\(title)")
                        self.captureSubscriptionsHTML(from: webView, attempt: attempt + 1)
                        return
                    }

                    DispatchQueue.main.async {
                        self.parent.isLoading = false
                    }
                    guard let html, !html.isEmpty else { return }
                    self.shouldCaptureSubscriptionsHTML = false
                    self.parent.onSubscriptionsHTML?(html)
                }
            }
        }

        private func steamIDFromSteamLoginSecureCookie(_ value: String) -> String? {
            let decoded = value.removingPercentEncoding ?? value
            let patterns = [
                #"^(\d{17})(?:\|\||%7C%7C)"#,
                #"(\d{17})"#
            ]

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
                      let range = Range(match.range(at: 1), in: decoded) else {
                    continue
                }
                return String(decoded[range])
            }

            return nil
        }

        private func completeLogin(with steamID: String) {
            DispatchQueue.main.async {
                guard !self.hasDetectedLogin else { return }
                self.hasDetectedLogin = true
                self.parent.steamID = steamID
                self.parent.isLoggedIn = true
                self.parent.onLoginSuccess?(steamID)
            }
        }
    }
}

// MARK: - Steam Login Sheet
/// 包装 SteamLoginWebView 的 Sheet 视图
struct SteamLoginSheet: View {
    @Binding var isPresented: Bool
    var onSyncSubscriptions: (() -> Void)? = nil
    var onSyncSubscriptionsHTML: ((String) -> Void)? = nil

    @State private var isLoggedIn = false
    @State private var steamID = ""
    @State private var isLoading = false
    @State private var subscriptionHTMLRequestID = 0

    @EnvironmentObject var workshopSourceManager: WorkshopSourceManager

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("Steam 登录")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
                .background(Color.white.opacity(0.1))

            // WebView
            ZStack {
                SteamLoginWebView(
                    isLoggedIn: $isLoggedIn,
                    steamID: $steamID,
                    isLoading: $isLoading,
                    subscriptionHTMLRequestID: $subscriptionHTMLRequestID
                ) { id in
                    // 登录成功回调
                    workshopSourceManager.steamProfileID = id
                    workshopSourceManager.refreshStoredSteamCredentials()
                    Task { @MainActor in
                        await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage()
                    }
                } onSubscriptionsHTML: { html in
                    Task { @MainActor in
                        isPresented = false
                        if let onSyncSubscriptionsHTML {
                            onSyncSubscriptionsHTML(html)
                        } else {
                            onSyncSubscriptions?()
                        }
                    }
                }

                if isLoading {
                    VStack {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在加载...")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.5))
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // 底部状态栏
            HStack {
                if isLoggedIn {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已登录")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    Button("同步订阅") {
                        Task { @MainActor in
                            await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage()
                            subscriptionHTMLRequestID += 1
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LiquidGlassColors.secondaryViolet)
                    )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                        Text("请在上方页面登录 Steam 账号")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Preview
#Preview {
    SteamLoginSheet(isPresented: .constant(true))
        .environmentObject(WorkshopSourceManager.shared)
}
