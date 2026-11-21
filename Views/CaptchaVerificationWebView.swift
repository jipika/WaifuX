import SwiftUI
import WebKit

// MARK: - 验证码验证 WebView
// 参考 Kazumi 的 WebView 验证码处理逻辑

struct CaptchaVerificationWebView: NSViewRepresentable {
    let url: URL
    var customUserAgent: String?
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // 启用 JavaScript
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // 使用默认数据存储以共享 Cookie
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        // 创建 WebView
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        webView.customUserAgent = AnimeVideoExtractor.nonempty(customUserAgent)
            ?? AnimeVideoExtractor.defaultBrowserUserAgent

        context.coordinator.requestedURL = url
        webView.load(URLRequest(url: url))
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 比较输入入口，站内验证跳转不能被SwiftUI的重绘重置。
        if context.coordinator.requestedURL != url {
            context.coordinator.requestedURL = url
            nsView.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.loadHTMLString("", baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var requestedURL: URL?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[CaptchaVerificationWebView] 页面加载完成 host=\(webView.url?.host ?? "unknown")")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let failure = error as NSError
            print("[CaptchaVerificationWebView] 页面加载失败 domain=\(failure.domain) code=\(failure.code)")
        }
    }
}

// MARK: - 预览
#Preview {
    CaptchaVerificationWebView(
        url: URL(string: "https://example.com")!,
        customUserAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
    )
    .frame(width: 800, height: 600)
}
