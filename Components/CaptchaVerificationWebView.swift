import SwiftUI
import WebKit

// MARK: - 内嵌浏览器（用于人机验证 / 滑块等）

struct CaptchaVerificationWebView: NSViewRepresentable {
    let url: URL
    var customUserAgent: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 860, height: 600), configuration: config)
        webView.navigationDelegate = context.coordinator
        if let ua = customUserAgent, !ua.isEmpty {
            webView.customUserAgent = ua
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        webView.load(request)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
    }
}
