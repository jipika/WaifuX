import Foundation
import WebKit

/// 将 WKWebView 使用的默认 `WKWebsiteDataStore` 中的 Cookie 同步到 `HTTPCookieStorage.shared`，
/// 使 `URLSession` / `AnimeParser` 后续请求能带上用户刚完成的验证码会话。
enum WebViewCookieSync {

    @MainActor
    static func syncWKWebsiteDataStoreToSharedHTTPCookieStorage() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let storage = HTTPCookieStorage.shared
                for cookie in cookies {
                    storage.setCookie(cookie)
                }
                continuation.resume()
            }
        }
    }
}
