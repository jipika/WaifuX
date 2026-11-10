import SwiftUI
import WebKit

// MARK: - Steam Login WebView
/// 基于 WKWebView 的 Steam 登录视图
/// 打开 Steam OpenID 登录页面，用户登录后获取 Session Cookie
struct SteamLoginWebView: NSViewRepresentable {
    @Binding var isLoggedIn: Bool
    @Binding var steamID: String
    @Binding var isLoading: Bool
    /// 当前 WebView URL，供 UI 显示
    @Binding var currentURL: String
    /// 用户点击"前往订阅页面"时递增此值，Coordinator 据此触发导航
    @Binding var navigateToSubscriptionCount: Int
    /// 设置为非空字符串时，WebView 导航到此 URL 并清空
    @Binding var navigateToCustomURL: String
    var onLoginSuccess: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // 保存 WebView 引用以便后续提取 Cookie 和手动导航
        context.coordinator.webView = webView

        // 加载 Steam 登录页面
        let loginURL = URL(string: "https://steamcommunity.com/login/home/?goto=")!
        webView.load(URLRequest(url: loginURL))

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 检测用户点击了"前往订阅页面"（计数器递增）
        context.coordinator.checkNavigateTrigger(navigateToSubscriptionCount, webView: nsView)
        // 检测用户从地址栏输入了自定义 URL
        context.coordinator.checkNavigateToCustomURL(navigateToCustomURL, webView: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// 导航状态机：不自动跳转，完全由用户点击控制
    private enum NavigationState {
        /// 初始状态，登录页加载中
        case initial
        /// 已有 SteamID（从 OpenID 或页面检测到），用户可点击"前往订阅页面"
        case hasSteamID(String)
        /// 已在 /profiles/{id}/myworkshopfiles/ 格式的订阅页（最终状态）
        case onProfileSubscriptionPage(String)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SteamLoginWebView
        weak var webView: WKWebView?
        private var state: NavigationState = .initial
        private var lastNavigateTriggerCount = 0

        /// 中转订阅页 URL（Steam 会重定向到 profiles/{id}/ 格式）
        private let redirectURL = "https://steamcommunity.com/myworkshopfiles/?appid=431960&sort=score&browsefilter=mysubscriptions"

        /// 完整的 profile 格式订阅页 URL
        private func profileSubscriptionURL(steamID: String) -> URL? {
            let urlString = "https://steamcommunity.com/profiles/\(steamID)/myworkshopfiles/?appid=431960&sort=score&browsefilter=mysubscriptions&view=imagewall&p=1&numperpage=30"
            return URL(string: urlString)
        }

        init(_ parent: SteamLoginWebView) {
            self.parent = parent
        }

        // MARK: - 由 updateNSView 调用，检测用户点击"前往订阅页面"
        func checkNavigateTrigger(_ count: Int, webView: WKWebView) {
            guard count > lastNavigateTriggerCount else { return }
            lastNavigateTriggerCount = count
            navigateToSubscription(webView: webView)
        }

        private var lastCustomURL: String = ""

        /// 由 updateNSView 调用，检测用户从地址栏输入了 URL
        func checkNavigateToCustomURL(_ urlString: String, webView: WKWebView) {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lastCustomURL else { return }
            lastCustomURL = trimmed
            // 清空 parent 的 binding，避免重复触发
            DispatchQueue.main.async {
                self.parent.currentURL = trimmed
                self.parent.navigateToCustomURL = ""
            }
            guard let url = Self.makeURL(from: trimmed) else { return }
            webView.load(URLRequest(url: url))
        }

        /// 将用户输入转为 URL，自动补全协议
        private static func makeURL(from string: String) -> URL? {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let url = URL(string: trimmed), url.scheme != nil {
                return url
            }
            // 没有协议前缀时补 https://
            return URL(string: "https://\(trimmed)")
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                if let url = webView.url {
                    self.parent.currentURL = url.absoluteString
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                if let url = webView.url {
                    self.parent.currentURL = url.absoluteString
                }
            }

            guard let url = webView.url else { return }
            let urlString = url.absoluteString

            switch state {

            // ── 初始状态：只检测，不自动跳转 ──
            case .initial:
                // 情况 A：已经在订阅页（支持 /profiles/ 和 /id/ 两种格式）
                if urlString.contains("myworkshopfiles") && urlString.contains("browsefilter=mysubscriptions") {
                    if let sid = extractSteamIDFromProfileURL(urlString) {
                        reachProfilePage(steamID: sid)
                        return
                    }
                    if let vanity = extractVanityNameFromProfileURL(urlString) {
                        reachProfilePage(steamID: vanity)
                        return
                    }
                    // 从页面内容提取 ID
                    tryExtractSteamIDFromPage(webView: webView)
                    return
                }
                // 情况 C：OpenID 回调（登录成功）
                if urlString.contains("openid.claimed_id") || urlString.contains("openid.identity") {
                    extractSteamIDFromOpenID(url: url, webView: webView)
                    return
                }
                // 情况 D：如果不在登录页（登录成功 / 已有 Cookie），标记 hasSteamID
                if !isLoginPage(urlString), urlString.contains("steamcommunity.com") {
                    // 尝试从页面提取 SteamID
                    tryExtractSteamIDFromPage(webView: webView)
                    // 如果提取不到也没关系，用户点击"前往订阅页面"后再拿
                    setLoggedInWithoutID()
                    return
                }
                // 情况 E：还在登录页 → 什么都不做

            // ── 已有 SteamID，等待用户点击"前往订阅页面" ──
            case .hasSteamID:
                // 不自动跳转，只是检查是否直接到了订阅页
                if urlString.contains("myworkshopfiles") && urlString.contains("browsefilter=mysubscriptions") {
                    if let sid = extractSteamIDFromProfileURL(urlString) {
                        reachProfilePage(steamID: sid)
                    } else if let vanity = extractVanityNameFromProfileURL(urlString) {
                        reachProfilePage(steamID: vanity)
                    }
                }

            // ── 已在最终订阅页，无需任何操作 ──
            case .onProfileSubscriptionPage:
                break
            }
        }

        // MARK: - 手动导航（用户触发）

        /// 用户点击"前往订阅页面"→ 加载中转 URL（Steam 自动重定向到 profiles/{id}/）
        func navigateToSubscription(webView: WKWebView) {
            // 如果已经有 SteamID，直接导航到 profile 格式 URL
            if case let .hasSteamID(sid) = state {
                if let url = profileSubscriptionURL(steamID: sid) {
                    state = .initial  // 重置状态，等待订阅页加载后重新检测
                    webView.load(URLRequest(url: url))
                    return
                }
            }
            // 否则走中转 URL（Steam 自动重定向到 profiles/{id}/）
            guard let url = URL(string: redirectURL) else { return }
            state = .initial
            webView.load(URLRequest(url: url))
        }

        // MARK: - 状态转换辅助

        private func reachProfilePage(steamID: String) {
            state = .onProfileSubscriptionPage(steamID)
            DispatchQueue.main.async {
                self.parent.steamID = steamID
                self.parent.isLoggedIn = true
                // 到达订阅页后调用登录成功回调（触发保存 SteamID）
                self.parent.onLoginSuccess?(steamID)
            }
        }

        /// 标记已登录但尚未拿到 SteamID（用户可点击"前往订阅页面"）
        private func setLoggedInWithoutID() {
            state = .hasSteamID("")
            DispatchQueue.main.async {
                self.parent.isLoggedIn = true
            }
        }

        /// 用 SteamID 标记已登录
        private func setLoggedInWithID(_ steamID: String) {
            state = .hasSteamID(steamID)
            DispatchQueue.main.async {
                self.parent.steamID = steamID
                self.parent.isLoggedIn = true
            }
        }

        // MARK: - URL 工具

        private func isLoginPage(_ urlString: String) -> Bool {
            urlString.contains("login/home") || urlString.contains("openid/login")
        }

        private func extractSteamIDFromProfileURL(_ urlString: String) -> String? {
            let pattern = "/profiles/(\\d{17})/"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)) else {
                return nil
            }
            return String(urlString[Range(match.range(at: 1), in: urlString)!])
        }

        private func extractVanityNameFromProfileURL(_ urlString: String) -> String? {
            let pattern = "/id/([a-zA-Z0-9_-]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)) else {
                return nil
            }
            return String(urlString[Range(match.range(at: 1), in: urlString)!])
        }

        // MARK: - SteamID 提取

        private func tryExtractSteamIDFromPage(webView: WKWebView) {
            webView.evaluateJavaScript("document.body.innerHTML") { result, error in
                guard let html = result as? String else { return }
                // 优先从页面 HTML 提取数字 steamID
                if let id = self.extractSteamIDFromPageHTML(html) {
                    self.setLoggedInWithID(id)
                    return
                }
                // 降级：从页面链接提取 /profiles/ 格式的 ID
                if let id = self.extractSteamIDFromPageLinks(html) {
                    self.setLoggedInWithID(id)
                    return
                }
                // 最后降级：从当前 URL 提取 /id/vanityname/ 格式的 vanity name
                if let vanityName = self.extractVanityNameFromCurrentURL() {
                    AppLogger.info(.media, "Using vanity name from URL: \(vanityName)")
                    self.setLoggedInWithID(vanityName)
                    return
                }
                // 如果在订阅页面且页面有数据，标记为已登录（允许后续同步）
                if let url = webView.url?.absoluteString,
                   url.contains("myworkshopfiles") && url.contains("browsefilter=mysubscriptions") {
                    self.checkPageHasWorkshopItems(webView: webView)
                }
            }
        }

        /// 从页面链接中提取 /profiles/ 格式的 steamID
        private func extractSteamIDFromPageLinks(_ html: String) -> String? {
            let pattern = "/profiles/(\\d{17})"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else {
                return nil
            }
            return String(html[Range(match.range(at: 1), in: html)!])
        }

        /// 从当前 URL 提取 /id/vanityname/ 格式的 vanity name
        private func extractVanityNameFromCurrentURL() -> String? {
            guard let url = webView?.url?.absoluteString else { return nil }
            let pattern = "/id/([a-zA-Z0-9_-]+)/"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) else {
                return nil
            }
            return String(url[Range(match.range(at: 1), in: url)!])
        }

        /// 检查页面是否有 Workshop 订阅数据，如果有则标记为已登录
        private func checkPageHasWorkshopItems(webView: WKWebView) {
            let js = """
            (function() {
                var items = document.querySelectorAll('.workshopItem, .workshopItemSubscription, [id*=\"Subscription\"], a[href*=\"/sharedfiles/filedetails/?id=\"]');
                return items.length;
            })()
            """
            webView.evaluateJavaScript(js) { result, error in
                guard let count = result as? Int, count > 0 else { return }
                AppLogger.info(.media, "Page has \(count) workshop items, marking as logged in")
                self.setLoggedInWithoutID()
            }
        }

        private func extractSteamIDFromPageHTML(_ html: String) -> String? {
            let patterns = [
                "steamid=\"(\\d{17})\"",
                "\"steamid\":\"(\\d{17})\"",
                "profile/(\\d{17})",
                "\"steamid64\":\"(\\d{17})\"",
                "\"accountid\":\"(\\d{5,10})\"",
                "\"accountid\":(\\d{5,10})",
                "g_steamID\\s*=\\s*\"(\\d{17})\"",
                "g_steamID\\s*=\\s*'(\\d{17})'",
                "\"steamid\":\\s*\"(\\d{17})\"",
                "data-steamid=\"(\\d{17})\"",
                "/profiles/(\\d{17})",
                "openid\\.claimed_id.*?(\\d{17})",
                "SteamId[\"']?\\s*[:=]\\s*[\"']?(\\d{17})"
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { continue }
                let id = String(html[Range(match.range(at: 1), in: html)!])
                // 如果是 accountid (较短)，需要转换为 steamID64
                if id.count >= 5 && id.count <= 10 {
                    if let accountID = UInt64(id) {
                        return String(accountID + 76561197960265728)
                    }
                }
                if id.count == 17 {
                    return id
                }
            }
            return nil
        }

        private func extractSteamIDFromOpenID(url: URL, webView: WKWebView) {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                for item in queryItems {
                    if item.name == "openid.identity" || item.name == "openid.claimed_id" {
                        if let value = item.value {
                            let components = value.components(separatedBy: "/")
                            if let steamID = components.last, steamID.count == 17, steamID.allSatisfy(\.isNumber) {
                                self.setLoggedInWithID(steamID)
                                return
                            }
                        }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }
    }
}

// MARK: - Cookie Transfer

/// 将 WKWebView 默认数据存储中的 Steam 登录 Cookie 同步到共享 HTTPCookieStorage，
/// 确保后续 URLSession 请求（NetworkService）携带有效的登录会话
private func transferSteamCookiesToSharedStorage() async {
    await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage(
        matchingDomains: ["steamcommunity.com", "steampowered.com", "steamcdn.com"]
    )
}

// MARK: - Steam Login Sheet
/// 包装 SteamLoginWebView 的 Sheet 视图
/// 流程：登录页 → 登录成功 → 跳转订阅页面 → 用户点击确认 → 关闭 Sheet → 父视图抓取数据
struct SteamLoginSheet: View {
    @Binding var isPresented: Bool
    @State private var isLoggedIn = false
    @State private var steamID = ""
    @State private var isLoading = false
    @State private var currentURL = ""
    @State private var urlBarText = ""
    @State private var navigateToSubscriptionCount = 0
    @State private var navigateToCustomURL = ""
    /// WebView 是否已到达订阅页面（onLoginSuccess 被调用）
    @State private var isOnSubscriptionPage = false

    @EnvironmentObject var workshopSourceManager: WorkshopSourceManager

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(t("steamLogin.title"))
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

            // 浏览器风格地址栏
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green.opacity(0.7))

                TextField(t("输入网址..."), text: $urlBarText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .onSubmit {
                        navigateToCustomURL = urlBarText
                    }

                if !urlBarText.isEmpty {
                    Button {
                        urlBarText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    navigateToCustomURL = urlBarText
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
                .disabled(urlBarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.1))

            // WebView
            ZStack {
                SteamLoginWebView(
                    isLoggedIn: $isLoggedIn,
                    steamID: $steamID,
                    isLoading: $isLoading,
                    currentURL: $currentURL,
                    navigateToSubscriptionCount: $navigateToSubscriptionCount,
                    navigateToCustomURL: $navigateToCustomURL,
                    onLoginSuccess: { id in
                        // 到达订阅页面后保存 SteamID
                        workshopSourceManager.steamProfileID = id
                        workshopSourceManager.refreshStoredSteamIdentity()
                        isOnSubscriptionPage = true
                    }
                )

                if isLoading {
                    VStack {
                        ProgressView()
                            .controlSize(.large)
                        Text(t("steamLogin.loading"))
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
                if isOnSubscriptionPage {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(t("steamLogin.reachedSubPage"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else if isLoggedIn {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(t("steamLogin.loggedInGoSub"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                        Text(t("steamLogin.pleaseLoginAbove"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Spacer()

                if isOnSubscriptionPage {
                    // 第二步：确认开始同步
                    Button(t("steamLogin.confirmSync")) {
                        Task {
                            await transferSteamCookiesToSharedStorage()
                            if !steamID.isEmpty {
                                workshopSourceManager.steamProfileID = steamID
                                workshopSourceManager.refreshStoredSteamIdentity()
                            }
                            isPresented = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor)
                    )
                } else if isLoggedIn {
                    // 第一步：前往订阅页面
                    Button(t("steamLogin.goToSubPage")) {
                        navigateToSubscriptionCount += 1
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onChange(of: currentURL) { _, newURL in
            urlBarText = newURL
        }
        .frame(width: 800, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Preview
#Preview {
    SteamLoginSheet(isPresented: .constant(true))
        .environmentObject(WorkshopSourceManager.shared)
}
