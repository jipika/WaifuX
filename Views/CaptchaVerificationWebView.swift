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
        
        // 设置 User-Agent
        if let userAgent = customUserAgent {
            webView.customUserAgent = userAgent
        }
        
        // 加载 URL
        let request = URLRequest(url: url)
        webView.load(request)
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 检查是否需要加载新 URL
        if nsView.url?.absoluteString != url.absoluteString {
            let request = URLRequest(url: url)
            nsView.load(request)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[CaptchaVerificationWebView] 页面加载完成: \(webView.url?.absoluteString ?? "unknown")")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[CaptchaVerificationWebView] 页面加载失败: \(error.localizedDescription)")
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
