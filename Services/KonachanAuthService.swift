import Foundation
import WebKit

/// KonaChan 的浏览器会话配置。
///
/// Cloudflare 的 `cf_clearance` Cookie 会与 User-Agent 绑定，因此内嵌 WebView、
/// API 请求和图片下载必须共享同一个浏览器标识。
enum KonachanRequestConfiguration {
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    static let siteURL = URL(string: "https://konachan.net")!
    static let loginURL = URL(string: "https://konachan.net/user/login")!
    static let cookieDomains = ["konachan.net", "konachan.com"]

    static var apiHeaders: [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Accept-Encoding": "gzip, deflate",
            "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,ja;q=0.6",
            "User-Agent": browserUserAgent,
            "Referer": "\(siteURL.absoluteString)/",
            "Origin": siteURL.absoluteString,
            "Connection": "keep-alive",
            "DNT": "1"
        ]
    }

    static var imageHeaders: [String: String] {
        [
            "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,ja;q=0.6",
            "User-Agent": browserUserAgent,
            "Referer": "\(siteURL.absoluteString)/"
        ]
    }

    static func matchesCookieDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cookieDomains.contains { normalized == $0 || normalized.hasSuffix(".\($0)") }
    }
}

/// 管理 KonaChan 账号登录和 Cloudflare 验证产生的浏览器会话。
///
/// 登录在 WKWebView 内完成；成功后的 Cookie 会同步到 `HTTPCookieStorage.shared`，
/// 让 `NetworkService` 与 Kingfisher 后续请求携带同一会话。
@MainActor
final class KonachanAuthService: ObservableObject {
    static let shared = KonachanAuthService()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var hasCloudflareClearance = false
    @Published private(set) var isCheckingSession = false

    var hasUsableSession: Bool {
        isLoggedIn || hasCloudflareClearance
    }

    var statusTitle: String {
        if isLoggedIn && hasCloudflareClearance {
            return "KonaChan 已登录，Cloudflare 验证已完成"
        }
        if hasCloudflareClearance {
            return "Cloudflare 验证已完成"
        }
        if isLoggedIn {
            return "KonaChan 账号已登录"
        }
        return "尚未建立 KonaChan 会话"
    }

    var statusSubtitle: String {
        if hasCloudflareClearance {
            return "会话 Cookie 已同步到应用请求与图片加载器。"
        }
        if isLoggedIn {
            return "账号会话已保存；若仍遇到 Cloudflare，请重新打开验证页完成挑战。"
        }
        return "登录 KonaChan 或完成 Cloudflare 人机验证后，可降低 403 / challenge 出现概率。"
    }

    private init() {}

    /// 从 WebView 和共享 Cookie 存储恢复会话状态。
    func checkLoginState() async {
        isCheckingSession = true
        defer { isCheckingSession = false }

        let webCookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        if webCookies.contains(where: { KonachanRequestConfiguration.matchesCookieDomain($0.domain) }) {
            await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage(
                matchingDomains: KonachanRequestConfiguration.cookieDomains
            )
        }

        let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter {
            KonachanRequestConfiguration.matchesCookieDomain($0.domain)
        }
        updateSessionState(from: cookies)
    }

    /// 由登录窗口在用户点“完成并保存”或页面跳转结束后调用。
    func saveWebSession() async {
        await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage(
            matchingDomains: KonachanRequestConfiguration.cookieDomains
        )
        await checkLoginState()
    }

    /// 清除 KonaChan 账号、Cloudflare Cookie 与 WebView 站点数据。
    func logout() async {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where KonachanRequestConfiguration.matchesCookieDomain(cookie.domain) {
            storage.deleteCookie(cookie)
        }

        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        for cookie in await cookieStore.allCookies()
        where KonachanRequestConfiguration.matchesCookieDomain(cookie.domain) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let matchingRecords = records.filter { record in
                    let domain = record.displayName.lowercased()
                    return KonachanRequestConfiguration.cookieDomains.contains {
                        domain == $0 || domain.hasSuffix(".\($0)")
                    }
                }
                dataStore.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    for: matchingRecords
                ) {
                    continuation.resume()
                }
            }
        }

        isLoggedIn = false
        hasCloudflareClearance = false
    }

    private func updateSessionState(from cookies: [HTTPCookie]) {
        hasCloudflareClearance = cookies.contains {
            $0.name.caseInsensitiveCompare("cf_clearance") == .orderedSame
        }

        // KonaChan 的 Moebooru 后端只会在当前用户非匿名时写入数值型 `user_id`。
        // `login`、session 等 Cookie 在匿名页面也可能存在，不能用来推断账号登录。
        let userIDCookie = cookies.first {
            $0.name.caseInsensitiveCompare("user_id") == .orderedSame
        }
        let userID = userIDCookie.flatMap {
            Int($0.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        isLoggedIn = (userID ?? 0) > 0
    }
}
