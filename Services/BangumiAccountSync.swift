import Foundation
import Combine
import Security

/// Inject a memory implementation in tests; production credentials never enter preferences or logs.
protocol BangumiAccountTokenStore: Sendable {
    func read() async throws -> Data?
    func save(_ data: Data) async throws
    func remove() async throws
}

actor BangumiAccountKeychain: BangumiAccountTokenStore {
    private let service = "com.waifux.bangumi.account"
    private let account = "personal-access-token"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BangumiAccountError.keychain }
        return data
    }
    func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BangumiAccountError.keychain }
        } else if status != errSecSuccess { throw BangumiAccountError.keychain }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BangumiAccountError.keychain }
    }
}

enum BangumiAccountError: Error, LocalizedError {
    case token, keychain, malformed, http(Int), cancelled
    var errorDescription: String? {
        switch self {
        case .token: return t("请填写有效的 Bangumi Personal Access Token。")
        case .keychain: return t("无法读写 Bangumi 钥匙串凭据，请检查系统钥匙串权限。")
        case .malformed: return t("Bangumi 返回的数据格式不完整。")
        case .http(401): return t("Token 无效或已过期，请更换。")
        case .http(403): return t("Bangumi 拒绝访问，请检查 Token 权限。")
        case .http(429): return t("请求过于频繁，请稍后重试。")
        case .http(let status): return String(format: t("Bangumi 请求失败（HTTP %d）。"), status)
        case .cancelled: return t("操作已取消。")
        }
    }
}

/// No network or Keychain access occurs in init. All remote operations are explicit UI actions.
@MainActor
final class BangumiAccountSync: ObservableObject {
    @Published private(set) var user: BangumiAccountUser?
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var report: BangumiSyncReport?
    @Published var conflictPolicy: BangumiSyncConflictPolicy = .newest

    private struct Credential: Codable { let token: String }
    private struct Page {
        let items: [BangumiAccountCollection]
        let total: Int
        let limit: Int
        let count: Int
        let invalid: Int
    }
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // PAT is scoped to the API origin; redirects are not part of this API contract.
            completionHandler(nil)
        }
    }
    private let redirectGuard = RedirectGuard()
    private let session: URLSession
    private let tokenStore: any BangumiAccountTokenStore
    private let readFavorites: @MainActor () -> [FavoriteAnime]
    private let writeFavorites: @MainActor ([FavoriteAnime]) -> Void
    private var token: String?
    private var generation = UUID()

    init(session: URLSession? = nil,
         tokenStore: any BangumiAccountTokenStore = BangumiAccountKeychain(),
         readFavorites: @escaping @MainActor () -> [FavoriteAnime] = { AnimeFavoriteStore.shared.allFavorites },
         writeFavorites: @escaping @MainActor ([FavoriteAnime]) -> Void = { AnimeFavoriteStore.shared.syncImportFavorites($0) }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
        self.tokenStore = tokenStore
        self.readFavorites = readFavorites
        self.writeFavorites = writeFavorites
    }

    /// Validate /v0/me before saving. This never imports or uploads collections.
    func signIn(personalAccessToken: String) async {
        guard !isBusy else { return }
        let candidate = personalAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains(where: { $0.isWhitespace }) else {
            error = BangumiAccountError.token.localizedDescription; return
        }
        isBusy = true; error = nil; report = nil
        let current = generation
        defer { if generation == current { isBusy = false } }
        do {
            let verified = try await validate(candidate)
            try check(current)
            try await tokenStore.save(JSONEncoder().encode(Credential(token: candidate)))
            try check(current)
            token = candidate; user = verified
        } catch { if generation == current { self.error = safeError(error) } }
    }

    /// User-triggered restore; merely opening the panel makes no external request.
    func restoreAccount() async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        let current = generation
        defer { if generation == current { isBusy = false } }
        do {
            guard let data = try await tokenStore.read() else { throw BangumiAccountError.token }
            let saved = try JSONDecoder().decode(Credential.self, from: data)
            let verified = try await validate(saved.token)
            try check(current)
            token = saved.token; user = verified
        } catch { if generation == current { self.error = safeError(error) } }
    }

    func signOut() async {
        // Invalidates in-flight reads before deleting only this integration's exact service/account key.
        generation = UUID(); token = nil; user = nil; report = nil; isBusy = true
        do { try await tokenStore.remove(); error = nil }
        catch { self.error = safeError(error) }
        isBusy = false
    }

    /// Imports complete pages even if a later page fails, without deleting unrelated local favorites.
    func importFromBangumi() async {
        guard !isBusy, let token, let user else { return }
        isBusy = true; error = nil; report = nil
        let current = generation
        let policy = conflictPolicy
        defer { if generation == current { isBusy = false } }
        do {
            let (items, failures) = try await collections(user: user, token: token, generation: current)
            try check(current)
            var result = BangumiSyncReport(); result.failures = failures
            // Read after the last await so edits made while downloading participate in conflict handling.
            let local = readFavorites()
            var imports: [FavoriteAnime] = []
            let uniqueItems = Dictionary(items.map { ($0.subjectID, $0) }, uniquingKeysWith: { first, second in
                (second.date ?? .distantPast) > (first.date ?? .distantPast) ? second : first
            }).values
            for item in uniqueItems {
                let matches = local.filter { $0.bangumiId == item.subjectID || $0.id == "bangumi_\(item.subjectID)" }
                let candidates: [FavoriteAnime?] = matches.isEmpty ? [nil] : matches.map { Optional($0) }
                for existing in candidates {
                    guard let merged = item.merged(with: existing, policy: policy) else {
                        result.failures.append(String(format: t("条目 %d：缺少有效状态、日期或标题"), item.subjectID)); continue
                    }
                    if merged == existing { result.skipped += 1 }
                    else { imports.append(merged); result.succeeded += 1 }
                }
            }
            writeFavorites(imports)
            report = result
        } catch { if generation == current { self.error = safeError(error) } }
    }

    /// Explicit outbound action. Only watch status is sent; existing remote comments/rating/tags stay intact.
    func uploadLocalStatuses() async {
        guard !isBusy, let token, let user else { return }
        isBusy = true; error = nil; report = nil
        let current = generation
        let policy = conflictPolicy
        defer { if generation == current { isBusy = false } }
        do {
            let (items, failures) = try await collections(user: user, token: token, generation: current)
            try check(current)
            guard failures.isEmpty else {
                var result = BangumiSyncReport(); result.failures = failures
                result.failures.append(t("远端列表不完整，本次未上传任何状态。"))
                report = result; return
            }
            let remote = Dictionary(items.map { ($0.subjectID, $0) }, uniquingKeysWith: { first, second in
                (second.date ?? .distantPast) > (first.date ?? .distantPast) ? second : first
            })
            let local = Dictionary(readFavorites().compactMap { favorite -> (Int, FavoriteAnime)? in
                guard let id = favorite.bangumiId, id > 0 else { return nil }; return (id, favorite)
            }, uniquingKeysWith: { $1.updatedAt > $0.updatedAt ? $1 : $0 })
            var result = BangumiSyncReport()
            result.skipped = readFavorites().filter { $0.bangumiId == nil || ($0.bangumiId ?? 0) <= 0 }.count
            for (id, favorite) in local.sorted(by: { $0.key < $1.key }) {
                try check(current)
                let existing = remote[id]
                if let existing {
                    guard let date = existing.date, existing.watchStatus != nil else {
                        result.failures.append(String(format: t("条目 %d：远端日期或状态无效，未上传"), id)); continue
                    }
                    if existing.watchStatus == favorite.watchStatus || policy == .remote ||
                        (policy == .newest && favorite.updatedAt <= date) { result.skipped += 1; continue }
                }
                do {
                    _ = try await request(path: "/v0/users/-/collections/\(id)", token: token,
                        method: existing == nil ? "POST" : "PATCH",
                        body: ["type": BangumiAccountCollection.remoteType(favorite.watchStatus)])
                    try check(current)
                    result.succeeded += 1
                } catch {
                    try check(current)
                    result.failures.append(String(format: t("条目 %d：%@"), id, safeError(error)))
                    if case BangumiAccountError.http(let code) = error, [401, 403, 429].contains(code) { break }
                }
                // Serial, bounded requests; cancellation/sign-out is rechecked before the next write.
                try await Task.sleep(for: .milliseconds(250))
            }
            try check(current); report = result
        } catch { if generation == current { self.error = safeError(error) } }
    }

    private func validate(_ token: String) async throws -> BangumiAccountUser {
        let data = try await request(path: "/v0/me", token: token)
        let user = try JSONDecoder().decode(BangumiAccountUser.self, from: data)
        guard user.id > 0, !user.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BangumiAccountError.malformed
        }
        return user
    }

    private func collections(user: BangumiAccountUser, token: String, generation current: UUID) async throws
        -> ([BangumiAccountCollection], [String]) {
        var offset = 0
        var total = Int.max
        var items: [BangumiAccountCollection] = []
        var failures: [String] = []
        // Numeric user id is accepted by Bangumi and avoids ambiguous path escaping of usernames.
        while offset < total && offset < 100_000 {
            try check(current)
            do {
                let data = try await request(path: "/v0/users/\(user.id)/collections", token: token,
                    query: [URLQueryItem(name: "subject_type", value: "2"), URLQueryItem(name: "limit", value: "50"),
                            URLQueryItem(name: "offset", value: String(offset))])
                try check(current)
                let page = try decodePage(data)
                total = page.total
                items.append(contentsOf: page.items)
                if page.invalid > 0 { failures.append(String(format: t("第 %d 页：%d 项格式异常"), offset / 50 + 1, page.invalid)) }
                if page.count == 0 {
                    if offset < total { failures.append(String(format: t("分页提前结束（%d/%d）。"), offset, total)) }
                    break
                }
                offset += page.count
            } catch {
                try check(current)
                if items.isEmpty { throw error }
                failures.append(String(format: t("offset %d：%@"), offset, safeError(error)))
                break
            }
        }
        if offset >= 100_000 && offset < total { failures.append(t("收藏数量超出单次同步上限。")) }
        return (items, failures)
    }

    private func decodePage(_ data: Data) throws -> Page {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [Any], let total = root["total"] as? Int, total >= 0,
              let limit = root["limit"] as? Int, limit > 0 else { throw BangumiAccountError.malformed }
        var items: [BangumiAccountCollection] = []
        var invalid = 0
        for row in rows {
            do {
                let encoded = try JSONSerialization.data(withJSONObject: row)
                let item = try JSONDecoder().decode(BangumiAccountCollection.self, from: encoded)
                guard item.subjectID > 0, item.date != nil, item.watchStatus != nil else { throw BangumiAccountError.malformed }
                items.append(item)
            } catch { invalid += 1 }
        }
        return Page(items: items, total: total, limit: limit, count: rows.count, invalid: invalid)
    }

    private func request(path: String, token: String, method: String = "GET", body: [String: Int]? = nil,
                         query: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(string: BangumiAPI.baseURL) else { throw BangumiAccountError.malformed }
        components.path = path; components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.scheme == "https", url.host == "api.bgm.tv" else { throw BangumiAccountError.malformed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("WaifuX (https://github.com/jipika/WaifuX)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
        guard let response = response as? HTTPURLResponse else { throw BangumiAccountError.malformed }
        guard (200...299).contains(response.statusCode) else { throw BangumiAccountError.http(response.statusCode) }
        return data
    }
    private func check(_ current: UUID) throws {
        guard current == generation, !Task.isCancelled else { throw BangumiAccountError.cancelled }
    }
    private func safeError(_ error: Error) -> String {
        // Never surface response bodies, URLs, or arbitrary network descriptions that might contain credentials.
        if let error = error as? BangumiAccountError { return error.localizedDescription }
        if error is CancellationError { return t("操作已取消。") }
        if error is DecodingError { return t("Bangumi 返回的数据格式不完整。") }
        return t("Bangumi 网络操作失败，请稍后重试。")
    }
}
