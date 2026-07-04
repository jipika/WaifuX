import Foundation
import WebKit

// MARK: - Pixiv 认证服务
///
/// 管理 Pixiv 登录状态和 cookie 桥接。
/// 登录通过 WKWebView 内嵌页面完成，cookie 桥接到 HTTPCookieStorage.shared
/// 供 PixivService 的 URLSession 请求自动携带。
@MainActor
class PixivAuthService: ObservableObject {
    static let shared = PixivAuthService()

    // MARK: - Published State

    /// 是否已登录
    @Published private(set) var isLoggedIn: Bool = false

    /// Pixiv 用户 ID（登录后从 cookie 或页面提取）
    @Published private(set) var pixivUserID: String?

    /// Pixiv 用户名
    @Published private(set) var pixivUserName: String?

    /// 是否正在检查登录状态
    @Published private(set) var isCheckingLoginState: Bool = false

    /// 是否显示登录窗口
    @Published var showLoginSheet: Bool = false

    // MARK: - Constants

    private let pixivLoginURL = "https://accounts.pixiv.net/login"
    private let pixivHomeURL = "https://www.pixiv.net/"
    private let cookieDomains = ["pixiv.net", ".pixiv.net"]
    private let userIDCookieName = "PHPSESSID"

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// 检查当前登录状态（从 HTTPCookieStorage 读取 cookie）
    func checkLoginState() async {
        isCheckingLoginState = true
        defer { isCheckingLoginState = false }

        // 检查 HTTPCookieStorage.shared 中是否有 Pixiv 的 session cookie
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        let pixivCookies = cookies.filter { cookie in
            cookieDomains.contains(where: { cookie.domain.hasSuffix($0) || cookie.domain == $0 })
        }

        // 调试日志：打印 Pixiv 域下所有 cookie 的名称和长度
        // 仅 DEBUG 构建启用；不打印 value 以防 cookie 泄露到系统日志。
        // 若调试需要 PHPSESSID 明文，可从 ~/Library/HTTPStorages/com.waifux.app.binarycookies 提取。
        #if DEBUG
        if !pixivCookies.isEmpty {
            print("🍪 [PixivAuthService] Pixiv cookies in HTTPCookieStorage.shared (\(pixivCookies.count) total):")
            for c in pixivCookies {
                print("🍪   - domain=\(c.domain) name=\(c.name) valueLen=\(c.value.lengthOfBytes(using: .utf8))")
            }
        } else {
            print("🍪 [PixivAuthService] No Pixiv cookies in HTTPCookieStorage.shared")
        }
        #endif

        // 检查是否有 PHPSESSID 或 device_token 等关键 cookie
        let hasSessionCookie = pixivCookies.contains { cookie in
            cookie.name == userIDCookieName || cookie.name == "device_token" || cookie.name == "login_remember"
        }

        if hasSessionCookie {
            // 尝试从 cookie 中提取用户 ID
            if let sessionCookie = pixivCookies.first(where: { $0.name == userIDCookieName }) {
                // PHPSESSID 格式通常是 {userID}_{hash}
                let parts = sessionCookie.value.split(separator: "_")
                if let firstPart = parts.first, let _ = Int(firstPart) {
                    pixivUserID = String(firstPart)
                }
            }
            
            // 尝试获取用户名（如果还没有）
            if pixivUserName == nil, let userID = pixivUserID {
                await fetchUserInfo(userID: userID)
            }
            
            isLoggedIn = true
            print("[PixivAuthService] 已登录, userID=\(pixivUserID ?? "unknown"), userName=\(pixivUserName ?? "unknown")")
        } else {
            // 也检查 WKWebsiteDataStore 中是否有 cookie（尚未桥接的情况）
            await checkWKWebViewCookies()
        }
    }
    
    /// 从 Pixiv API 获取用户信息
    private func fetchUserInfo(userID: String) async {
        do {
            // 尝试访问用户作品 API 来验证会话并获取用户名
            let url = URL(string: "https://www.pixiv.net/ajax/user/\(userID)/profile/all")!
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15.7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            // 解析响应获取用户名
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let body = json["body"] as? [String: Any],
               let illusts = body["illusts"] as? [String: Any],
               let firstKey = illusts.keys.first,
               let firstIllust = illusts[firstKey] as? [String: Any],
               let userName = firstIllust["userName"] as? String {
                await MainActor.run {
                    self.pixivUserName = userName
                }
                print("[PixivAuthService] 获取到用户名: \(userName)")
            }
        } catch {
            print("[PixivAuthService] 获取用户信息失败: \(error)")
            // 如果获取失败，至少我们有 userID
        }
    }

    /// 打开登录窗口
    func login() {
        showLoginSheet = true
    }

    /// 登录成功后的回调（由 PixivLoginView 调用）
    func onLoginSuccess() async {
        // 桥接 WKWebsiteDataStore 的 cookie 到 HTTPCookieStorage.shared
        await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage(
            matchingDomains: ["pixiv.net", ".pixiv.net"]
        )

        // 等待 cookie 生效
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 重新检查登录状态（会获取用户信息）
        await checkLoginState()

        // 关闭登录窗口
        showLoginSheet = false
    }

    /// 登出
    func logout() async {
        // 清除 HTTPCookieStorage 中的 Pixiv cookie
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        for cookie in cookies {
            if cookieDomains.contains(where: { cookie.domain.hasSuffix($0) || cookie.domain == $0 }) {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }

        // 清除 WKWebsiteDataStore 中的 Pixiv cookie（等待完成）
        let dataStore = WKWebsiteDataStore.default()
        await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let pixivRecords = records.filter { record in
                    record.displayName.lowercased().contains("pixiv")
                }
                dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: pixivRecords) {
                    print("[PixivAuthService] 已清除 WKWebsiteDataStore 中的 Pixiv 数据")
                    continuation.resume()
                }
            }
        }

        // 重置状态
        isLoggedIn = false
        pixivUserID = nil
        pixivUserName = nil
        showLoginSheet = false

        print("[PixivAuthService] 已登出")
    }

    // MARK: - Private

    /// 检查 WKWebsiteDataStore 中的 cookie
    private func checkWKWebViewCookies() async {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await cookieStore.allCookies()

        let pixivCookies = cookies.filter { cookie in
            cookie.domain.hasSuffix("pixiv.net") || cookie.domain == "pixiv.net"
        }

        // 调试日志：打印 WKWebsiteDataStore 中 Pixiv 域下的所有 cookie 名称
        #if DEBUG
        if !pixivCookies.isEmpty {
            print("🍪 [PixivAuthService] Pixiv cookies in WKWebsiteDataStore (\(pixivCookies.count) total):")
            for c in pixivCookies {
                print("🍪   - domain=\(c.domain) name=\(c.name) valueLen=\(c.value.lengthOfBytes(using: .utf8))")
            }
        }
        #endif

        let hasSessionCookie = pixivCookies.contains { cookie in
            cookie.name == userIDCookieName || cookie.name == "device_token"
        }

        if hasSessionCookie {
            // 桥接到 HTTPCookieStorage
            await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage(
                matchingDomains: ["pixiv.net", ".pixiv.net"]
            )
            isLoggedIn = true
            print("[PixivAuthService] 从 WKWebView cookie 恢复登录状态")
        }
    }
}

// MARK: - WKHTTPCookieStore Extension

extension WKHTTPCookieStore {
    /// 获取所有 cookie（async 版本）
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}
