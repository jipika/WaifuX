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

// MARK: - WebView Cookie 同步工具
// 参考 Kazumi PluginCookieManager 逻辑

enum WebViewCookieSync {
    /// 将 WKWebView 的 Cookie 同步到共享的 HTTPCookieStorage
    /// 在验证码验证完成后调用，确保后续 HTTP 请求能携带验证后的 Cookie
    static func syncWKWebsiteDataStoreToSharedHTTPCookieStorage() async {
        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        
        // 获取所有 Cookie
        let cookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        
        // 同步到共享存储
        let sharedStorage = HTTPCookieStorage.shared
        for cookie in cookies {
            sharedStorage.setCookie(cookie)
            print("[WebViewCookieSync] 同步 Cookie: \(cookie.name)=\(cookie.value.prefix(20))... domain:\(cookie.domain)")
        }
        
        print("[WebViewCookieSync] 同步完成，共 \(cookies.count) 个 Cookie")
    }
    
    /// 清除所有 WebView Cookie（用于调试或重置验证状态）
    static func clearAllCookies() async {
        let dataStore = WKWebsiteDataStore.default()
        
        // 清除 WKWebView 的 Cookie
        let cookieStore = dataStore.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        
        for cookie in cookies {
            cookieStore.delete(cookie)
        }
        
        // 清除共享存储的 Cookie
        let sharedStorage = HTTPCookieStorage.shared
        if let sharedCookies = sharedStorage.cookies {
            for cookie in sharedCookies {
                sharedStorage.deleteCookie(cookie)
            }
        }
        
        print("[WebViewCookieSync] 已清除所有 Cookie")
    }
    
    /// 为指定规则获取 Cookie 字符串（用于 HTTP 请求头）
    static func getCookieString(forURL url: URL) -> String {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
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
