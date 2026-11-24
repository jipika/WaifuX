import Foundation
import CryptoKit
import Security

/// 弹弹play开放弹幕网络的应用凭证（AppId + AppSecret）。
/// 开放 API 自 2025 起强制鉴权：无凭证时所有请求返回 403「Missing Authentication Headers」。
/// 凭证来源（按优先级）：
/// 1. 进程环境变量 `WAIFUX_DANDAN_APPID` / `WAIFUX_DANDAN_APPSECRET`（本地开发）
/// 2. 构建注入的 `Info.plist`（CI 由 GitHub Secrets 写入，键 `WaifuXDandanAppID` / `WaifuXDandanAppSecret`）
/// 3. 历史版本用户在设置页填写、保存在 Keychain 的本机凭证（UI 入口已移除，仅兼容读取）
/// 签名算法（官方文档）：`base64(sha256(AppId + Timestamp + Path + AppSecret))`，Path 不含域名与查询串。
enum DanmakuCredentials {
    private static let keychainService = "com.waifux.app.dandanplay"
    private static let appIDAccount = "appid"
    private static let appSecretAccount = "appsecret"

    struct Pair: Equatable {
        let appID: String
        let appSecret: String
    }

    /// 当前生效凭证；未配置返回 nil。每次请求读取，设置页保存后立即生效。
    static var current: Pair? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["WAIFUX_DANDAN_APPID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let secret = env["WAIFUX_DANDAN_APPSECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty, !secret.isEmpty {
            return Pair(appID: id, appSecret: secret)
        }
        if let id = (Bundle.main.object(forInfoDictionaryKey: "WaifuXDandanAppID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let secret = (Bundle.main.object(forInfoDictionaryKey: "WaifuXDandanAppSecret") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty, !secret.isEmpty, !id.hasPrefix("$(") {
            return Pair(appID: id, appSecret: secret)
        }
        if let id = keychainRead(account: appIDAccount),
           let secret = keychainRead(account: appSecretAccount),
           !id.isEmpty, !secret.isEmpty {
            return Pair(appID: id, appSecret: secret)
        }
        return nil
    }

    static var isConfigured: Bool { current != nil }

    /// 设置页展示用：当前凭证来源描述（不含密钥本体）。
    enum Source: Equatable { case environment, buildConfiguration, keychain, none }
    static var activeSource: Source {
        let env = ProcessInfo.processInfo.environment
        if let id = env["WAIFUX_DANDAN_APPID"], let secret = env["WAIFUX_DANDAN_APPSECRET"],
           !id.isEmpty, !secret.isEmpty { return .environment }
        if let id = Bundle.main.object(forInfoDictionaryKey: "WaifuXDandanAppID") as? String,
           let secret = Bundle.main.object(forInfoDictionaryKey: "WaifuXDandanAppSecret") as? String,
           !id.isEmpty, !secret.isEmpty, !id.hasPrefix("$(") { return .buildConfiguration }
        if keychainRead(account: appIDAccount) != nil, keychainRead(account: appSecretAccount) != nil { return .keychain }
        return .none
    }

    /// 历史 UI 遗留的 Keychain 写入接口（设置页填写入口已移除，当前无调用方）。
    /// 传空清除。返回是否成功。
    @discardableResult
    static func saveUserCredentials(appID: String, appSecret: String) -> Bool {
        let id = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || secret.isEmpty {
            keychainDelete(account: appIDAccount)
            keychainDelete(account: appSecretAccount)
            return true
        }
        return keychainWrite(account: appIDAccount, value: id)
            && keychainWrite(account: appSecretAccount, value: secret)
    }

    static func userSavedAppID() -> String? { keychainRead(account: appIDAccount) }

    /// 生成签名请求头。path 形如 `/api/v2/comment/123450001`。
    static func authenticationHeaders(path: String, timestamp: Int = Int(Date().timeIntervalSince1970)) -> [String: String]? {
        guard let pair = current else { return nil }
        let data = Data((pair.appID + String(timestamp) + path + pair.appSecret).utf8)
        let signature = Data(SHA256.hash(data: data)).base64EncodedString()
        return [
            "X-AppId": pair.appID,
            "X-Timestamp": String(timestamp),
            "X-Signature": signature,
            "X-Auth": "1"
        ]
    }

    // MARK: - Keychain（generic password，仅本机，不同步）

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    private static func keychainRead(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    private static func keychainWrite(account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private static func keychainDelete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
