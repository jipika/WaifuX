import SwiftUI
import WebKit

// MARK: - Pixiv 登录视图
///
/// 基于 WKWebView 的 Pixiv 登录界面。
/// 用户登录后自动桥接 cookie 到 HTTPCookieStorage.shared。
struct PixivLoginView: NSViewRepresentable {
    @ObservedObject var authService: PixivAuthService

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // 加载 Pixiv 登录页面
        let loginURL = URL(string: "https://accounts.pixiv.net/login")!
        webView.load(URLRequest(url: loginURL))

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 无需更新
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: PixivLoginView

        init(_ parent: PixivLoginView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 检查是否登录成功（重定向到首页）
            if let url = webView.url {
                let urlString = url.absoluteString

                // 登录成功后会重定向到首页
                if urlString == "https://www.pixiv.net/" ||
                   urlString == "https://www.pixiv.net" ||
                   urlString.hasPrefix("https://www.pixiv.net/?") {
                    // 检查是否有登录态 cookie
                    checkLoginStatus(webView: webView)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[PixivLoginView] 导航失败: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[PixivLoginView]  provisional 导航失败: \(error.localizedDescription)")
        }

        /// 检查登录状态
        private func checkLoginStatus(webView: WKWebView) {
            // 检查是否有 PHPSESSID cookie
            let httpCookieStorage = HTTPCookieStorage.shared
            let cookies = httpCookieStorage.cookies ?? []

            let hasPixivSession = cookies.contains { cookie in
                (cookie.domain.hasSuffix("pixiv.net") || cookie.domain == "pixiv.net") &&
                cookie.name == "PHPSESSID"
            }

            if hasPixivSession {
                // 登录成功，通知 authService
                Task { @MainActor in
                    await parent.authService.onLoginSuccess()
                }
            }
        }
    }
}

// MARK: - Pixiv 登录 Sheet

struct PixivLoginSheet: View {
    @ObservedObject var authService: PixivAuthService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("Pixiv 登录")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // WebView
            PixivLoginView(authService: authService)
                .frame(minWidth: 800, minHeight: 600)

            Divider()

            // 底部提示
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("登录后可访问更多内容。Cookie 仅存储在本地。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 800, minHeight: 700)
    }
}
