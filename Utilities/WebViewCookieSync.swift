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

    @MainActor
    static func cookieHeader(for url: URL) async -> String {
        let wkCookies = await allWKCookies()
        let sharedCookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let cookies = (wkCookies + sharedCookies)
            .filter { cookie in
                cookieMatches(cookie, url: url)
            }

        var seen = Set<String>()
        return cookies
            .sorted { $0.path.count > $1.path.count }
            .compactMap { cookie in
                let key = "\(cookie.name)|\(cookie.domain)|\(cookie.path)"
                guard seen.insert(key).inserted else { return nil }
                return "\(cookie.name)=\(cookie.value)"
            }
            .joined(separator: "; ")
    }

    @MainActor
    private static func allWKCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func cookieMatches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard host == domain || host.hasSuffix(".\(domain)") else { return false }

        let requestPath = url.path.isEmpty ? "/" : url.path
        guard requestPath.hasPrefix(cookie.path) || cookie.path == "/" else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        return true
    }
}
