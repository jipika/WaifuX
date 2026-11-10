import Foundation
import Combine
import Security
import CFNetwork

enum SteamServiceLoginState: Equatable, Codable {
    case idle
    case loggingIn
    case waitingForQR(challengeURL: String)
    case waitingForMobileConfirmation
    case waitingForCode
    case success
    case failed(String)
}

/// 一条订阅记录（来自 SteamKit2 CPublishedFile_GetUserFiles，type=mysubscriptions）。
struct SteamSubscriptionItem: Codable, Sendable {
    let workshopID: String
    let subscribedAt: Date
    let updatedAt: Date
    let contentHash: String
    let fileSize: Int64
}

/// listSubscriptions 的一页结果；`total` 是服务端总数，精确翻页用。
struct SteamSubscriptionPage: Codable, Sendable {
    let total: Int
    let startIndex: Int
    let items: [SteamSubscriptionItem]
}

/// listUserFiles 的一页结果（CPublishedFile_GetUserFiles，type=myfiles）：
/// 某作者在本应用下的公开创意工坊作品 ID，按创建时间从新到旧。
/// `nextStartIndex` 按服务端实际返回条数推进；`total` 是精确总数。
struct SteamUserFilesPage: Codable, Sendable {
    let total: Int
    let startIndex: Int
    let nextStartIndex: Int
    let workshopIDs: [String]
}

enum SteamServiceError: LocalizedError {
    case unavailable(String)
    case busy
    case notAuthenticated
    case authenticationFailed(String, String?)
    case downloadFailed(String, String?)
    case requestFailed(String, String?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .busy: return t("Steam 登录正在进行中。")
        case .notAuthenticated: return t("Steam 服务尚未登录，请到「设置 → Steam 服务」中登录。")
        case .authenticationFailed(let message, _): return message
        case .downloadFailed(let message, _): return message
        case .requestFailed(let message, _): return message
        case .cancelled: return t("Steam 下载已取消。")
        }
    }

    var errorCode: String? {
        switch self {
        case .authenticationFailed(_, let code), .downloadFailed(_, let code), .requestFailed(_, let code):
            return code
        default:
            return nil
        }
    }
}

/// Owns one long-lived SteamKit2 process and keeps its refresh-token session
/// alive across Workshop downloads and app launches.
final class SteamServiceManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = SteamServiceManager()

    @Published private(set) var isAvailable = false
    @Published private(set) var isLoggedIn = false
    @Published private(set) var accountName = ""
    @Published private(set) var steamID = ""
    @Published private(set) var loginState: SteamServiceLoginState = .idle

    private let ioQueue = DispatchQueue(label: "com.waifux.app.steam-service", qos: .userInitiated)
    private let keychainService = "com.waifux.app.SteamService"
    private let usernameKey = "steam_service_username"
    private let loginIDKey = "steam_service_login_id"
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var requestHandlers: [String: (Bool, String?, String?, [String: Any]?) -> Void] = [:]
    private var downloadHandlers: [String: (String, String?, String?, [String: Any]?) -> Void] = [:]
    private var loginContinuation: CheckedContinuation<Void, Error>?
    private var loginRequestID: String?
    private var loginUsername = ""
    private var restoringSession = false
    private var restoreWaiters: [CheckedContinuation<Bool, Never>] = []
    private var explicitShutdown = false
    private var restartWorkItem: DispatchWorkItem?
    private var restartCount = 0
    private var loginID: UInt32
    private var sessionIsLoggedIn = false
    private var lastRestoreFailureMessage: String?
    private var launchedProxySignature = ""
    private var restartingForProxyChange = false
    private var qrLoginActive = false
    private var qrChallenge = ""
    private var qrChallengeUpdatedAt: Date?
    private var qrWatchdogWorkItem: DispatchWorkItem?
    private static let qrChallengeStaleInterval: TimeInterval = 30

    @MainActor func backgroundSnapshot() -> [String: Any] {
        ["available": isAvailable, "loggedIn": isLoggedIn, "account": accountName, "steamID": steamID, "login": (try? JSONEncoder().encode(loginState)) ?? Data()]
    }

    private override init() {
        // 所有偏好读取都延迟到 ioQueue；singleton init 不读 UserDefaults。
        loginID = 0
        super.init()
        // 在 ioQueue 上延迟读偏好，避开 singleton init 期间直接读 UserDefaults。
        if !BackgroundRuntimeRole.isRemoteUI {
            ioQueue.async { [weak self] in self?.restoreLoginIDIfNeeded() }
        }
        if BackgroundRuntimeRole.isRemoteUI {
            Task { @MainActor in
                BackgroundRuntimeBridge.observe { [weak self] snapshot in
                    guard let self, let values = snapshot["steam"] as? [String: Any] else { return }
                    self.applyBackgroundSnapshot(values)
                }
            }
        }
    }

    @MainActor private func applyBackgroundSnapshot(_ values: [String: Any]) {
        isAvailable = values["available"] as? Bool ?? false
        isLoggedIn = values["loggedIn"] as? Bool ?? false
        accountName = values["account"] as? String ?? ""
        steamID = values["steamID"] as? String ?? ""
        if let data = values["login"] as? Data,
           let state = try? JSONDecoder().decode(SteamServiceLoginState.self, from: data) {
            loginState = state
        }
    }

    func start() {
        if BackgroundRuntimeRole.isRemoteUI {
            Task { @MainActor in
                do {
                    let data = try await BackgroundRuntimeBridge.request("steam.start", [:])
                    if let values = data["steam"] as? [String: Any] { applyBackgroundSnapshot(values) }
                } catch {
                    AppLogger.error(.download, "Steam 后台会话启动失败", metadata: ["error": error.localizedDescription])
                }
            }
            return
        }

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.explicitShutdown = false
            self.startOnQueue()
        }
    }

    /// 后台启动时只恢复已有会话；没有保存账号时不创建服务进程。
    func restoreSavedSessionIfAvailable() {
        guard !BackgroundRuntimeRole.isRemoteUI else { return }
        ioQueue.async { [weak self] in
            guard let self, self.savedUsernameOnQueue()?.isEmpty == false else { return }
            self.explicitShutdown = false
            self.startOnQueue()
        }
    }

    func shutdown() {
        if BackgroundRuntimeRole.isRemoteUI { Task { @MainActor in BackgroundRuntimeBridge.send("steam.shutdown", [:]) }; return }

        ioQueue.sync {
            explicitShutdown = true
            restartWorkItem?.cancel()
            restartWorkItem = nil
            sendCommandOnQueue("shutdown")
            stopQRLoginOnQueue()
            try? input?.close()
            let deadline = Date().addingTimeInterval(1.5)
            while process?.isRunning == true && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if process?.isRunning == true {
                process?.terminate()
            }
            process = nil
            input = nil
            updateOnMain {
                self.isAvailable = false
                self.isLoggedIn = false
                self.accountName = ""
                self.steamID = ""
                self.loginState = .idle
            }
        }
    }

    /// Returns false only when the helper is not embedded in the current app
    /// build. It does not perform a network request.
    var canUseEmbeddedService: Bool {
        serviceLaunchConfiguration() != nil
    }

    func login(username: String, password: String, guardCode: String? = nil) async throws {
        if BackgroundRuntimeRole.isRemoteUI {
            let arguments = try BackgroundPropertyList.encode(["username": username, "password": password].merging(guardCode.map { ["code": $0] } ?? [:]) { _, new in new })
            try await BackgroundRuntimeBridge.requestVoid("steam.login.wait", arguments: arguments)
            return
        }

        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            throw SteamServiceError.authenticationFailed(LocalizationService.shared.t("Steam 用户名和密码不能为空。"), "MISSING_CREDENTIALS")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SteamServiceError.unavailable(LocalizationService.shared.t("Steam 服务已释放。")))
                    return
                }
                guard self.loginContinuation == nil else {
                    continuation.resume(throwing: SteamServiceError.busy)
                    return
                }
                guard self.ensureStartedOnQueue() else {
                    continuation.resume(throwing: SteamServiceError.unavailable(
                        LocalizationService.shared.t("WaifuX Steam 服务不可用，请重新构建应用。")
                    ))
                    return
                }

                self.loginContinuation = continuation
                self.loginUsername = username
                self.restoringSession = false
                self.updateOnMain {
                    self.loginState = .loggingIn
                }
                var fields: [String: Any] = [
                    "username": username,
                    "password": password,
                    "loginId": self.loginID
                ]
                if case .value(let guardData) = self.keychainRead(
                    account: self.guardDataAccount(username)
                ) {
                    fields["guardData"] = guardData
                }
                if let guardCode = guardCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !guardCode.isEmpty {
                    fields["guardCode"] = guardCode
                }
                self.sendCommandOnQueue("loginPassword", fields: fields) { [weak self] success, message, errorCode, _ in
                    guard let self, !success else { return }
                    self.finishLoginOnQueue(.failure(
                        SteamServiceError.authenticationFailed(
                            message ?? LocalizationService.shared.t("Steam 登录失败。"),
                            errorCode
                        )
                    ))
                }
            }
        }
    }

    /// QR-code login: asks the helper for a Steam challenge URL, renders it as
    /// a QR code for the Steam mobile app, and stores the resulting refresh
    /// token through the shared `loggedIn` event.
    func loginWithQR() {
        if BackgroundRuntimeRole.isRemoteUI { Task { @MainActor in BackgroundRuntimeBridge.send("steam.loginWithQR", [:]) }; return }

        ioQueue.async { [weak self] in
            guard let self else { return }
            guard loginContinuation == nil else { return }
            guard ensureStartedOnQueue() else {
                updateOnMain {
                    self.loginState = .failed(LocalizationService.shared.t("WaifuX Steam 服务不可用，请重新构建应用。"))
                }
                return
            }
            startQRLoginOnQueue()
        }
    }

    private func startQRLoginOnQueue() {
        stopQRWatchdogOnQueue()
        qrLoginActive = true
        qrChallenge = ""
        qrChallengeUpdatedAt = nil
        restoringSession = false
        updateOnMain {
            self.loginState = .loggingIn
        }
        sendCommandOnQueue("loginQr", fields: ["loginId": loginID]) { [weak self] success, message, errorCode, _ in
            guard let self, !success else { return }
            self.qrLoginActive = false
            self.updateOnMain {
                self.loginState = .failed(message ?? LocalizationService.shared.t("Steam 二维码登录失败。"))
            }
            self.resolveRestoreWaitersOnQueue(isLoggedIn: self.sessionIsLoggedIn)
        }
    }

    /// Steam rotates the QR challenge URL periodically; if no fresh URL
    /// arrives within the stale interval, rebuild the QR session so the
    /// on-screen code never outlives its validity window.
    private func scheduleQRWatchdogOnQueue() {
        qrWatchdogWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.qrLoginActive else { return }
            let staleSince = self.qrChallengeUpdatedAt ?? .distantPast
            guard Date().timeIntervalSince(staleSince) >= Self.qrChallengeStaleInterval else {
                self.scheduleQRWatchdogOnQueue()
                return
            }
            self.startQRLoginOnQueue()
        }
        qrWatchdogWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + Self.qrChallengeStaleInterval, execute: work)
    }

    private func stopQRWatchdogOnQueue() {
        qrWatchdogWorkItem?.cancel()
        qrWatchdogWorkItem = nil
    }

    private func stopQRLoginOnQueue() {
        qrLoginActive = false
        stopQRWatchdogOnQueue()
        qrChallenge = ""
        qrChallengeUpdatedAt = nil
    }

    func submitGuardCode(_ code: String) {
        if BackgroundRuntimeRole.isRemoteUI { Task { @MainActor in BackgroundRuntimeBridge.send("steam.submitGuardCode", ["code": code]) }; return }

        ioQueue.async { [weak self] in
            guard let self, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sendCommandOnQueue("submitChallenge", fields: ["code": code])
        }
    }

    func cancelLogin() {
        if BackgroundRuntimeRole.isRemoteUI { Task { @MainActor in BackgroundRuntimeBridge.send("steam.cancelLogin", [:]) }; return }

        ioQueue.async { [weak self] in
            guard let self else { return }
            sendCommandOnQueue("cancelLogin")
            stopQRLoginOnQueue()
            resolveRestoreWaitersOnQueue(isLoggedIn: sessionIsLoggedIn)
            finishLoginOnQueue(.failure(SteamServiceError.cancelled))
        }
    }

    func logout() {
        if BackgroundRuntimeRole.isRemoteUI { Task { @MainActor in BackgroundRuntimeBridge.send("steam.logout", [:]) }; return }

        ioQueue.async { [weak self] in
            guard let self else { return }
            let username = WaifuXPreferences.shared.string(forKey: usernameKey) ?? accountName
            sendCommandOnQueue("logout")
            stopQRLoginOnQueue()
            if !username.isEmpty {
                _ = deleteKeychainValue(account: refreshTokenAccount(username))
                _ = deleteKeychainValue(account: guardDataAccount(username))
            }
            WaifuXPreferences.shared.removeObject(forKey: usernameKey)
            WaifuXPreferences.shared.removeLegacySessionValue(forKey: usernameKey)
            WaifuXPreferences.shared.removeLegacySessionValue(forKey: loginIDKey)
            lastRestoreFailureMessage = nil
            sessionIsLoggedIn = false
            resolveRestoreWaitersOnQueue(isLoggedIn: false)
            updateOnMain {
                self.isLoggedIn = false
                self.accountName = ""
                self.steamID = ""
                self.loginState = .idle
            }
        }
    }

    func downloadItem(
        workshopID: String,
        outputRoot: URL,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if BackgroundRuntimeRole.isRemoteUI {
            let url = try await BackgroundRuntimeBridge.requestCodable("steam.download.wait", arguments: BackgroundPropertyList.encode(["id": workshopID, "root": outputRoot.absoluteString]), resultKey: "url", as: URL.self)
            progressHandler?(1)
            return url
        }

        guard !workshopID.isEmpty else {
            throw SteamServiceError.downloadFailed(LocalizationService.shared.t("Workshop ID 不能为空。"), "INVALID_WORKSHOP_ID")
        }
        guard await waitForRestoredSessionIfNeeded() else {
            throw sessionRestoreError()
        }

        // waitForRestoredSessionIfNeeded starts and restores the service once;
        // do not start another authentication between readiness and download.
        let taskID = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                ioQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: SteamServiceError.unavailable(LocalizationService.shared.t("Steam 服务已释放。")))
                        return
                    }
                    guard self.ensureStartedOnQueue() else {
                        continuation.resume(throwing: SteamServiceError.unavailable(
                            LocalizationService.shared.t("WaifuX Steam 服务不可用，请重新构建应用。")
                        ))
                        return
                    }
                    guard self.sessionIsLoggedIn else {
                        continuation.resume(throwing: SteamServiceError.notAuthenticated)
                        return
                    }

                    self.downloadHandlers[taskID] = { state, message, errorCode, payload in
                        switch state {
                        case "downloading":
                            if let received = payload?["receivedBytes"] as? NSNumber,
                               let total = payload?["totalBytes"] as? NSNumber,
                               total.doubleValue > 0 {
                                progressHandler?(min(1, max(0, received.doubleValue / total.doubleValue)))
                            }
                        case "completed":
                            guard let path = payload?["outputPath"] as? String else {
                                continuation.resume(throwing: SteamServiceError.downloadFailed(
                                    LocalizationService.shared.t("Steam 服务未返回下载路径。"),
                                    "MISSING_OUTPUT_PATH"
                                ))
                                return
                            }
                            continuation.resume(returning: URL(fileURLWithPath: path))
                        case "cancelled":
                            continuation.resume(throwing: SteamServiceError.cancelled)
                        case "failed":
                            continuation.resume(throwing: SteamServiceError.downloadFailed(
                                message ?? LocalizationService.shared.t("Workshop 下载失败。"),
                                errorCode
                            ))
                        default:
                            break
                        }
                        if state == "completed" || state == "cancelled" || state == "failed" {
                            self.downloadHandlers.removeValue(forKey: taskID)
                        }
                    }

                    self.sendCommandOnQueue("download", fields: [
                        "taskId": taskID,
                        "workshopId": workshopID,
                        "outputRoot": outputRoot.path
                    ]) { [weak self] success, message, errorCode, _ in
                        guard let self, !success else { return }
                        let handler = self.downloadHandlers.removeValue(forKey: taskID)
                        handler?("failed", message, errorCode, nil)
                    }
                }
            }
        }, onCancel: {
            self.cancelDownload(taskID: taskID)
        })
    }

    func cancelDownload(taskID: String) {
        if BackgroundRuntimeRole.isRemoteUI { Task { @MainActor in BackgroundRuntimeBridge.send("steam.cancelDownload", ["taskID": taskID]) }; return }

        ioQueue.async { [weak self] in
            self?.sendCommandOnQueue("cancelDownload", fields: ["taskId": taskID])
        }
    }

    /// 从 Steam 服务（SteamKit2 协议层）分页拉取已订阅的创意工坊物品，
    /// 不依赖 WebView cookie，也不解析 steamcommunity HTML。
    /// 服务端每页固定 50 条，调用方按 `startIndex + items.count < total` 翻页。
    ///
    /// 与 `downloadItem` 相同：先等会话恢复完成再发命令。helper 重启/换代理
    /// 的窗口期里主线程的 `isLoggedIn` 是旧值 true，而 ioQueue 上的
    /// `sessionIsLoggedIn` 已被终止处理清掉——不等待就会误报"需要重新登录"。
    func fetchSubscriptions(startIndex: Int) async throws -> SteamSubscriptionPage {
        if BackgroundRuntimeRole.isRemoteUI {
            return try await BackgroundRuntimeBridge.requestCodable("steam.subscriptions.wait", arguments: BackgroundPropertyList.encode(["start": startIndex]), resultKey: "page", as: SteamSubscriptionPage.self)
        }

        guard await waitForRestoredSessionIfNeeded() else {
            throw sessionRestoreError()
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SteamSubscriptionPage, Error>) in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SteamServiceError.unavailable(LocalizationService.shared.t("Steam 服务已释放。")))
                    return
                }
                guard self.sessionIsLoggedIn else {
                    continuation.resume(throwing: SteamServiceError.notAuthenticated)
                    return
                }
                self.sendCommandOnQueue("listSubscriptions", fields: ["startIndex": max(0, startIndex)]) { _, message, errorCode, data in
                    guard let data else {
                        continuation.resume(throwing: SteamServiceError.downloadFailed(
                            message ?? LocalizationService.shared.t("获取订阅列表失败。"),
                            errorCode
                        ))
                        return
                    }
                    guard let total = data["total"] as? Int,
                          let returnedStart = data["startIndex"] as? Int,
                          let rawItems = data["items"] as? [[String: Any]] else {
                        continuation.resume(throwing: SteamServiceError.downloadFailed(
                            LocalizationService.shared.t("Steam 服务返回的订阅数据格式异常。"),
                            "MALFORMED_SUBSCRIPTIONS"
                        ))
                        return
                    }
                    let items = rawItems.compactMap { payload -> SteamSubscriptionItem? in
                        guard let workshopID = payload["workshopId"] as? String,
                              !workshopID.isEmpty else { return nil }
                        let subscribedAt = (payload["subscribedAt"] as? NSNumber)?.doubleValue ?? 0
                        let updatedAt = (payload["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                        return SteamSubscriptionItem(
                            workshopID: workshopID,
                            subscribedAt: Date(timeIntervalSince1970: subscribedAt),
                            updatedAt: Date(timeIntervalSince1970: updatedAt),
                            contentHash: (payload["contentHash"] as? String) ?? "",
                            fileSize: (payload["fileSize"] as? NSNumber)?.int64Value ?? 0
                        )
                    }
                    continuation.resume(returning: SteamSubscriptionPage(
                        total: total,
                        startIndex: returnedStart,
                        items: items
                    ))
                }
            }
        }
    }

    /// 走协议层分页拉取某作者的公开创意工坊作品 ID（新到旧）。
    /// 社区作者页会对匿名访客隐藏带成人内容描述符的作品（列表和 `of N` 都不含），
    /// 这里拿到的是完整列表与精确总数。
    func fetchUserFiles(creatorSteamID: String, startIndex: Int, count: Int) async throws -> SteamUserFilesPage {
        if BackgroundRuntimeRole.isRemoteUI {
            return try await BackgroundRuntimeBridge.requestCodable(
                "steam.userFiles.wait",
                arguments: BackgroundPropertyList.encode([
                    "creator": creatorSteamID,
                    "start": startIndex,
                    "count": count
                ]),
                resultKey: "page",
                as: SteamUserFilesPage.self
            )
        }
        guard await waitForRestoredSessionIfNeeded() else {
            throw SteamServiceError.notAuthenticated
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SteamUserFilesPage, Error>) in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SteamServiceError.unavailable(LocalizationService.shared.t("Steam 服务已释放。")))
                    return
                }
                guard self.sessionIsLoggedIn else {
                    continuation.resume(throwing: SteamServiceError.notAuthenticated)
                    return
                }
                self.sendCommandOnQueue("listUserFiles", fields: [
                    "creatorSteamId": creatorSteamID,
                    "startIndex": max(0, startIndex),
                    "count": max(1, count)
                ]) { _, message, errorCode, data in
                    if errorCode == "NOT_AUTHENTICATED" {
                        continuation.resume(throwing: SteamServiceError.notAuthenticated)
                        return
                    }
                    guard let data else {
                        continuation.resume(throwing: SteamServiceError.requestFailed(
                            message ?? LocalizationService.shared.t("获取作者作品列表失败。"),
                            errorCode
                        ))
                        return
                    }
                    guard let total = data["total"] as? Int,
                          let returnedStart = data["startIndex"] as? Int,
                          let nextStart = data["nextStartIndex"] as? Int,
                          let ids = data["workshopIds"] as? [String] else {
                        continuation.resume(throwing: SteamServiceError.requestFailed(
                            LocalizationService.shared.t("Steam 服务返回的作者作品数据格式异常。"),
                            "MALFORMED_USER_FILES"
                        ))
                        return
                    }
                    continuation.resume(returning: SteamUserFilesPage(
                        total: total,
                        startIndex: returnedStart,
                        nextStartIndex: nextStart,
                        workshopIDs: ids.filter { !$0.isEmpty }
                    ))
                }
            }
        }
    }

    /// 修改当前账号对单个 Workshop 项目的订阅状态。
    func setSubscribed(_ subscribed: Bool, workshopID: String) async throws {
        guard !workshopID.isEmpty else {
            throw SteamServiceError.downloadFailed(LocalizationService.shared.t("Workshop ID 不能为空。"), "INVALID_WORKSHOP_ID")
        }
        if BackgroundRuntimeRole.isRemoteUI {
            try await BackgroundRuntimeBridge.requestVoid(
                "steam.subscription.wait",
                arguments: BackgroundPropertyList.encode(["id": workshopID, "subscribed": subscribed])
            )
            return
        }
        guard await waitForRestoredSessionIfNeeded() else {
            throw SteamServiceError.notAuthenticated
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SteamServiceError.unavailable(LocalizationService.shared.t("Steam 服务已释放。")))
                    return
                }
                guard self.sessionIsLoggedIn else {
                    continuation.resume(throwing: SteamServiceError.notAuthenticated)
                    return
                }
                self.sendCommandOnQueue(
                    subscribed ? "subscribe" : "unsubscribe",
                    fields: ["workshopId": workshopID]
                ) { success, message, errorCode, _ in
                    if success {
                        continuation.resume()
                    } else if errorCode == "NOT_AUTHENTICATED" {
                        continuation.resume(throwing: SteamServiceError.notAuthenticated)
                    } else {
                        continuation.resume(throwing: SteamServiceError.requestFailed(
                            message ?? (subscribed ? LocalizationService.shared.t("订阅 Workshop 项目失败。") : LocalizationService.shared.t("取消订阅 Workshop 项目失败。")),
                            errorCode
                        ))
                    }
                }
            }
        }
    }

    /// 批量查询订阅状态，供本地库去重；服务每次最多处理 100 个 ID。
    func fetchSubscriptionStates(workshopIDs: [String]) async throws -> [String: Bool] {
        if BackgroundRuntimeRole.isRemoteUI {
            return try await BackgroundRuntimeBridge.requestCodable(
                "steam.subscriptionStates.wait",
                // AgentArguments.decode expects JSON Data inside the property-list envelope.
                arguments: BackgroundPropertyList.encode(["ids": try JSONEncoder().encode(workshopIDs)]),
                resultKey: "states",
                as: [String: Bool].self
            )
        }
        guard await waitForRestoredSessionIfNeeded() else {
            throw SteamServiceError.notAuthenticated
        }
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SteamServiceError.unavailable(LocalizationService.shared.t("Steam 服务已释放。")))
                    return
                }
                guard self.sessionIsLoggedIn else {
                    continuation.resume(throwing: SteamServiceError.notAuthenticated)
                    return
                }
                self.sendCommandOnQueue("checkSubscriptionStates", fields: ["workshopIds": workshopIDs]) { success, message, errorCode, data in
                    guard success, let items = data?["items"] as? [[String: Any]] else {
                        if errorCode == "NOT_AUTHENTICATED" {
                            continuation.resume(throwing: SteamServiceError.notAuthenticated)
                        } else {
                            continuation.resume(throwing: SteamServiceError.requestFailed(
                                message ?? LocalizationService.shared.t("获取 Workshop 订阅状态失败。"), errorCode
                            ))
                        }
                        return
                    }
                    var states: [String: Bool] = [:]
                    let requestedIDs = Set(workshopIDs)
                    for item in items {
                        guard let id = item["workshopId"] as? String,
                              requestedIDs.contains(id),
                              let subscribed = item["subscribed"] as? Bool,
                              states[id] == nil else {
                            continuation.resume(throwing: SteamServiceError.requestFailed(
                                LocalizationService.shared.t("Steam 服务返回的订阅状态数据格式异常，请重试。"),
                                "MALFORMED_SUBSCRIPTION_STATES"
                            ))
                            return
                        }
                        states[id] = subscribed
                    }
                    // Missing is unknown, not false: never subscribe based on a partial response.
                    guard Set(states.keys) == requestedIDs else {
                        continuation.resume(throwing: SteamServiceError.requestFailed(
                            LocalizationService.shared.t("Steam 服务返回的订阅状态不完整，请重试。"),
                            "MALFORMED_SUBSCRIPTION_STATES"
                        ))
                        return
                    }
                    continuation.resume(returning: states)
                }
            }
        }
    }

    private func startOnQueue() {
        if process?.isRunning == true {
            // 子进程的环境变量在启动时固定；系统代理开关/换端口后重启服务，
            // 让新代理以环境变量形式注入（终止处理链会自动拉起新进程）。
            if Self.readSystemProxySettings().signature != launchedProxySignature {
                NSLog("[SteamService] 检测到系统代理变化，重启 Steam 服务使新代理生效。")
                restartingForProxyChange = true
                process?.terminate()
                return
            }
            restoreSessionOnQueue()
            return
        }
        guard let launch = serviceLaunchConfiguration() else {
            updateOnMain {
                self.isAvailable = false
                self.loginState = .failed(LocalizationService.shared.t("WaifuX Steam 服务组件不可用。"))
            }
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.ioQueue.async {
                self.handleTerminationOnQueue(
                    status: terminatedProcess.terminationStatus,
                    reason: terminatedProcess.terminationReason
                )
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { self?.consumeOutputOnQueue(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[WaifuXSteamService] %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            restartCount = 0
            launchedProxySignature = Self.readSystemProxySettings().signature
            updateOnMain {
                self.isAvailable = true
            }
            sendCommandOnQueue("hello")
            restoreSessionOnQueue()
        } catch {
            handleServiceFailureOnQueue(String(format: LocalizationService.shared.t("Steam 服务启动失败：%@"), String(describing: error.localizedDescription)))
        }
    }

    private func ensureStartedOnQueue() -> Bool {
        if process?.isRunning != true {
            startOnQueue()
        }
        return process?.isRunning == true
    }

    @discardableResult
    private func restoreSessionOnQueue() -> Bool {
        // start() is also called by settings and downloads. Replaying a saved
        // token into an already authenticated SteamClient yields InvalidParam;
        // the subsequent failure used to erase the next launch's credentials.
        guard !sessionIsLoggedIn, loginContinuation == nil, !qrLoginActive,
              !restoringSession else { return restoringSession }
        restoreLoginIDIfNeeded()
        guard let username = savedUsernameOnQueue(), !username.isEmpty else {
            return false
        }
        switch keychainRead(account: refreshTokenAccount(username)) {
        case .value(let token):
            restoringSession = true
            loginUsername = username
            updateOnMain {
                self.loginState = .loggingIn
            }
            sendCommandOnQueue("restoreSession", fields: [
                "username": username,
                "refreshToken": token,
                "loginId": loginID
            ])
            return true
        case .notFound:
            markRestorationFailureOnQueue(
                LocalizationService.shared.t("已保存 Steam 账号，但钥匙串中没有会话令牌。请到「设置 → Steam 服务」重新登录。"),
                reason: "refreshTokenMissing",
                status: errSecItemNotFound
            )
        case .failure(let status):
            markRestorationFailureOnQueue(
                String(format: LocalizationService.shared.t("无法读取钥匙串中的 Steam 会话（错误 %@）。请到「设置 → Steam 服务」重新登录。"), String(describing: status)),
                reason: "refreshTokenReadFailed",
                status: status
            )
        }
        return false
    }

    private func savedUsernameOnQueue() -> String? {
        let preferences = WaifuXPreferences.shared
        let username = preferences.string(forKey: usernameKey)
            ?? preferences.legacyStringForSessionRestore(usernameKey)
        return username?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markRestorationFailureOnQueue(_ message: String, reason: String, status: OSStatus) {
        lastRestoreFailureMessage = message
        AppLogger.error(.download, "Steam 会话恢复不可用", metadata: [
            "reason": reason,
            "keychainStatus": String(status)
        ])
        updateOnMain {
            self.isLoggedIn = false
            self.loginState = .failed(message)
        }
    }

    private func restoreLoginIDIfNeeded() {
        guard loginID == 0 else { return }
        let preferences = WaifuXPreferences.shared
        let saved: Int?
        if let current = preferences.object(forKey: loginIDKey) as? NSNumber {
            saved = current.intValue
        } else {
            saved = preferences.legacyIntegerForSessionRestore(loginIDKey)
        }
        guard let value = saved.flatMap({ UInt32(exactly: $0) }), value != 0 else { return }
        loginID = value
    }

    private func waitForRestoredSessionIfNeeded() async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                // A prior shutdown or failed restart can leave a saved token
                // without a live .NET process. Restore must first reconnect
                // the service or its waiter would never receive a response.
                guard self.ensureStartedOnQueue() else {
                    continuation.resume(returning: false)
                    return
                }
                self.restoreLoginIDIfNeeded()
                if self.sessionIsLoggedIn {
                    continuation.resume(returning: true)
                    return
                }
                if !self.restoringSession {
                    self.restoreSessionOnQueue()
                }
                if self.restoringSession || self.loginContinuation != nil || self.qrLoginActive {
                    self.restoreWaiters.append(continuation)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func resolveRestoreWaitersOnQueue(isLoggedIn: Bool) {
        let waiters = restoreWaiters
        restoreWaiters.removeAll()
        waiters.forEach { $0.resume(returning: isLoggedIn) }
    }

    private func consumeOutputOnQueue(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let event = object as? [String: Any] else {
                continue
            }
            handleEventOnQueue(event)
        }
    }

    private func handleEventOnQueue(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "response":
            let requestID = event["requestId"] as? String
            let success = (event["success"] as? Bool) ?? false
            let handler = requestID.flatMap { requestHandlers.removeValue(forKey: $0) }
            handler?(
                success,
                event["message"] as? String,
                event["errorCode"] as? String,
                event["data"] as? [String: Any]
            )
        case "authState":
            handleAuthEventOnQueue(event)
        case "downloadState":
            guard let taskID = event["taskId"] as? String,
                  let state = event["state"] as? String,
                  let handler = downloadHandlers[taskID] else { return }
            handler(
                state,
                event["message"] as? String,
                event["errorCode"] as? String,
                event
            )
        default:
            break
        }
    }

    private func handleAuthEventOnQueue(_ event: [String: Any]) {
        guard let state = event["state"] as? String else { return }
        let username = event["accountName"] as? String
        let resolvedUsername = username?.isEmpty == false ? username! : loginUsername
        switch state {
        case "connecting", "authenticating", "reconnecting":
            if state == "reconnecting" {
                sessionIsLoggedIn = false
                // SteamKit2 already owns this recovery. Downloads join it instead
                // of replaying restoreSession into another active authentication.
                restoringSession = true
            }
            updateOnMain {
                self.loginState = .loggingIn
                if state == "reconnecting" {
                    self.isLoggedIn = false
                }
            }
        case "waitingMobile":
            updateOnMain {
                self.loginState = .waitingForMobileConfirmation
            }
        case "mobileCode", "emailCode":
            updateOnMain {
                self.loginState = .waitingForCode
            }
        case "qr":
            if let challenge = event["challengeUrl"] as? String, !challenge.isEmpty {
                if challenge != qrChallenge {
                    qrChallenge = challenge
                    qrChallengeUpdatedAt = Date()
                }
                scheduleQRWatchdogOnQueue()
                updateOnMain {
                    self.loginState = .waitingForQR(challengeURL: challenge)
                }
            }
        case "loggedIn":
            stopQRLoginOnQueue()
            let resolvedSteamID = event["steamId"] as? String ?? steamID
            var persistenceFailure: OSStatus?
            if let token = event["refreshToken"] as? String, !token.isEmpty {
                let status = setKeychainValue(token, account: refreshTokenAccount(resolvedUsername))
                if status != errSecSuccess { persistenceFailure = status }
            } else {
                // Restored/reconnected events contain no new token. Do not report
                // persistence success unless the existing item can still be read.
                switch keychainRead(account: refreshTokenAccount(resolvedUsername)) {
                case .value: break
                case .notFound: persistenceFailure = errSecItemNotFound
                case .failure(let status): persistenceFailure = status
                }
            }
            let persistenceMessage = persistenceFailure.map { status in
                String(format: LocalizationService.shared.t("Steam 已连接，但会话未能保存到 macOS 钥匙串（错误 %@）。重启或更新后将需要重新登录，请检查钥匙串访问权限后重试登录。"), String(describing: status))
            }
            if let status = persistenceFailure {
                AppLogger.error(.download, "Steam 会话令牌保存失败", metadata: ["keychainStatus": String(status)])
            }
            if let guardData = event["guardData"] as? String, !guardData.isEmpty {
                _ = setKeychainValue(guardData, account: guardDataAccount(resolvedUsername))
            }
            WaifuXPreferences.shared.set(resolvedUsername, forKey: usernameKey)
            lastRestoreFailureMessage = nil
            AppLogger.info(.download, "Steam 会话已连接", metadata: ["steamID": resolvedSteamID, "tokenPersisted": persistenceFailure == nil ? "1" : "0"])
            restoringSession = false
            restartCount = 0
            sessionIsLoggedIn = true
            resolveRestoreWaitersOnQueue(isLoggedIn: true)
            updateOnMain {
                self.isLoggedIn = true
                self.accountName = resolvedUsername
                self.steamID = resolvedSteamID
                self.loginState = persistenceMessage.map { .failed($0) } ?? .success
            }
            if loginContinuation != nil {
                if let persistenceMessage {
                    finishLoginOnQueue(.failure(SteamServiceError.authenticationFailed(
                        persistenceMessage, "SESSION_PERSIST_FAILED"
                    )))
                } else {
                    finishLoginOnQueue(.success(()))
                }
            }
        case "loggedOut":
            let wasRestoring = restoringSession
            let message = event["message"] as? String
                ?? LocalizationService.shared.t("Steam 会话已断开，请重试；如仍失败，请到「设置 → Steam 服务」重新登录。")
            if wasRestoring { lastRestoreFailureMessage = message }
            stopQRLoginOnQueue()
            restoringSession = false
            sessionIsLoggedIn = false
            resolveRestoreWaitersOnQueue(isLoggedIn: false)
            updateOnMain {
                self.isLoggedIn = false
                self.steamID = ""
                self.loginState = wasRestoring ? .failed(message) : .idle
            }
            // Cancellation, reconnects and auth replacement also emit loggedOut.
            // Only explicit logout() removes persisted tokens and guard data.
        case "failed":
            let message = event["message"] as? String ?? t("Steam 登录失败。")
            let errorCode = event["errorCode"] as? String
            let wasRestoring = restoringSession
            lastRestoreFailureMessage = wasRestoring ? message : nil
            if wasRestoring {
                AppLogger.error(.download, "Steam 会话恢复失败", metadata: [
                    "error": message,
                    "code": errorCode ?? ""
                ])
            }
            stopQRLoginOnQueue()
            restoringSession = false
            sessionIsLoggedIn = false
            resolveRestoreWaitersOnQueue(isLoggedIn: false)
            // AUTH_FAILED also wraps InvalidParam and other login-state errors;
            // it is not proof that the stored token or guard data is revoked.
            // Keep both until explicit logout or a successful login replaces them.
            updateOnMain {
                self.isLoggedIn = false
                self.loginState = .failed(message)
            }
            if loginContinuation != nil {
                finishLoginOnQueue(.failure(SteamServiceError.authenticationFailed(message, errorCode)))
            }
        default:
            break
        }
    }

    private func finishLoginOnQueue(_ result: Result<Void, Error>) {
        guard let continuation = loginContinuation else { return }
        loginContinuation = nil
        loginRequestID = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            resolveRestoreWaitersOnQueue(isLoggedIn: sessionIsLoggedIn)
            continuation.resume(throwing: error)
        }
    }

    private func sendCommandOnQueue(
        _ command: String,
        fields: [String: Any] = [:],
        completion: ((Bool, String?, String?, [String: Any]?) -> Void)? = nil
    ) {
        guard let input, process?.isRunning == true else {
            completion?(false, LocalizationService.shared.t("Steam 服务未运行。"), "SERVICE_UNAVAILABLE", nil)
            return
        }
        let requestID = UUID().uuidString
        var payload: [String: Any] = ["command": command, "requestId": requestID]
        fields.forEach { payload[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion?(false, LocalizationService.shared.t("Steam 服务命令编码失败。"), "ENCODE_FAILED", nil)
            return
        }
        if let completion {
            requestHandlers[requestID] = completion
        }
        var line = data
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            requestHandlers.removeValue(forKey: requestID)
            completion?(false, error.localizedDescription, "WRITE_FAILED", nil)
        }
        if command == "loginPassword" {
            loginRequestID = requestID
        }
    }

    private func handleTerminationOnQueue(status: Int32, reason: Process.TerminationReason) {
        process = nil
        input = nil
        sessionIsLoggedIn = false
        stopQRLoginOnQueue()
        // 恢复流程随进程一起死了：复位标志，否则重启后的 restoreSessionOnQueue
        // 会被这个残留 guard 挡住，restoreWaiters 里的等待者永远无人唤醒。
        restoringSession = false
        resolveRestoreWaitersOnQueue(isLoggedIn: false)
        updateOnMain {
            self.isAvailable = false
        }
        if loginContinuation != nil {
            finishLoginOnQueue(.failure(SteamServiceError.unavailable(
                String(format: LocalizationService.shared.t("Steam 服务已退出（%@，%@）。"), String(describing: status), String(describing: reason.rawValue))
            )))
        }
        let pendingDownloads = downloadHandlers
        downloadHandlers.removeAll()
        pendingDownloads.values.forEach { $0("failed", LocalizationService.shared.t("Steam 服务已退出。"), "SERVICE_TERMINATED", nil) }
        if restartingForProxyChange {
            // 代理变化触发的计划内重启不消耗崩溃重试预算。
            restartingForProxyChange = false
            restartCount = 0
        }
        guard !explicitShutdown, restartCount < 5 else { return }
        let delay = min(30.0, pow(2.0, Double(restartCount)))
        restartCount += 1
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startOnQueue()
        }
        restartWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleServiceFailureOnQueue(_ message: String) {
        updateOnMain {
            self.isAvailable = false
            self.loginState = .failed(message)
        }
        finishLoginOnQueue(.failure(SteamServiceError.unavailable(message)))
    }

    private struct LaunchConfiguration {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    // MARK: - 系统代理桥接

    /// macOS 系统代理设置（ClashX/Surge/小火箭类工具写入 System Configuration 的那份）。
    /// .NET 在 macOS 上只认 http_proxy/https_proxy/all_proxy 环境变量，不读系统代理，
    /// 而 GUI 启动的子进程又拿不到终端里的环境变量；这里负责把系统代理翻译成
    /// 标准环境变量注入 Steam 服务子进程，否则用户的 VPN 代理不到 Steam 流量。
    private struct SystemProxySettings {
        var httpProxy: URL?
        var httpsProxy: URL?
        var socksProxy: URL?
        var exceptions: [String]
        var signature: String
    }

    private static func readSystemProxySettings() -> SystemProxySettings {
        var settings = SystemProxySettings(httpProxy: nil, httpsProxy: nil, socksProxy: nil,
                                           exceptions: [], signature: "none")
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return settings
        }
        func string(_ key: String) -> String? {
            (raw[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func number(_ key: String) -> Int? {
            (raw[key] as? NSNumber)?.intValue
        }
        func proxyURL(scheme: String, hostKey: String, portKey: String, enabledKey: String) -> URL? {
            guard number(enabledKey) == 1,
                  let host = string(hostKey),
                  let port = number(portKey), port > 0 else { return nil }
            return URL(string: "\(scheme)://\(host):\(port)")
        }
        settings.httpProxy = proxyURL(scheme: "http", hostKey: "HTTPProxy", portKey: "HTTPPort", enabledKey: "HTTPEnable")
        settings.httpsProxy = proxyURL(scheme: "http", hostKey: "HTTPSProxy", portKey: "HTTPSPort", enabledKey: "HTTPSEnable")
        settings.socksProxy = proxyURL(scheme: "socks5", hostKey: "SOCKSProxy", portKey: "SOCKSPort", enabledKey: "SOCKSEnable")
        settings.exceptions = (raw["ExceptionsList"] as? [String]) ?? []
        settings.signature = [
            settings.httpProxy?.absoluteString ?? "-",
            settings.httpsProxy?.absoluteString ?? "-",
            settings.socksProxy?.absoluteString ?? "-",
            settings.exceptions.sorted().joined(separator: ",")
        ].joined(separator: "|")
        return settings
    }

    /// 系统代理未启用时返回 nil：保留进程现有环境变量，不覆盖手动设置。
    private static func proxyEnvironmentOverrides() -> [String: String]? {
        let proxy = readSystemProxySettings()
        guard proxy.httpProxy != nil || proxy.httpsProxy != nil || proxy.socksProxy != nil else { return nil }
        var overrides: [String: String] = [:]
        if let url = proxy.httpProxy {
            overrides["http_proxy"] = url.absoluteString
            overrides["HTTP_PROXY"] = url.absoluteString
        }
        if let url = proxy.httpsProxy {
            overrides["https_proxy"] = url.absoluteString
            overrides["HTTPS_PROXY"] = url.absoluteString
        }
        if let url = proxy.socksProxy {
            overrides["all_proxy"] = url.absoluteString
            overrides["ALL_PROXY"] = url.absoluteString
        }
        let noProxy = (["localhost", "127.0.0.1", "::1"] + proxy.exceptions).joined(separator: ",")
        overrides["no_proxy"] = noProxy
        overrides["NO_PROXY"] = noProxy
        return overrides
    }

    private static func proxyEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        if let overrides = proxyEnvironmentOverrides() {
            if let proxy = overrides["https_proxy"] ?? overrides["http_proxy"] ?? overrides["all_proxy"] {
                NSLog("[SteamService] 系统代理已启用，注入 Steam 服务环境变量：%@", proxy)
            }
            overrides.forEach { environment[$0.key] = $0.value }
        }
        return environment
    }

    private func serviceLaunchConfiguration() -> LaunchConfiguration? {
        if let configured = ProcessInfo.processInfo.environment["WAIFUX_STEAM_SERVICE_PATH"],
           !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return LaunchConfiguration(
                    executableURL: url,
                    arguments: [],
                    environment: Self.proxyEnvironment(ProcessInfo.processInfo.environment)
                )
            }
        }

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        return nil
        #endif

        let candidates: [URL] = [
            WaifuXHostBundle.resourcesURL.appendingPathComponent("WaifuXSteamService/\(architecture)") ,
            WaifuXHostBundle.resourcesURL.appendingPathComponent("Resources/WaifuXSteamService/\(architecture)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/SteamService/\(architecture)")
        ].compactMap { $0 }

        for root in candidates {
            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            let executable = runtime.appendingPathComponent("dotnet")
            let assembly = root.appendingPathComponent("app/WaifuXSteamService.dll")
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  FileManager.default.fileExists(atPath: assembly.path) else { continue }
            var environment = ProcessInfo.processInfo.environment
            environment["DOTNET_ROOT"] = runtime.path
            return LaunchConfiguration(
                executableURL: executable,
                arguments: [assembly.path],
                environment: Self.proxyEnvironment(environment)
            )
        }
        return nil
    }

    /// 会话恢复失败时给出真实原因：没有保存账号才是“尚未登录”；
    /// 有账号但令牌读取失败、恢复被拒等场景保留具体信息，避免一律
    /// 报“未登录”误导用户重新走登录流程。
    private func sessionRestoreError() -> SteamServiceError {
        if let message = lastRestoreFailureMessage {
            return .authenticationFailed(message, "SESSION_RESTORE_FAILED")
        }
        return .notAuthenticated
    }

    private func refreshTokenAccount(_ username: String) -> String {
        "refresh-token:\(username.lowercased())"
    }

    private func guardDataAccount(_ username: String) -> String {
        "guard-data:\(username.lowercased())"
    }

    private enum KeychainRead {
        case value(String)
        case notFound
        case failure(OSStatus)
    }

    private func keychainRead(account: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return .failure(errSecDecode)
        }
        return .value(value)
    }

    private func setKeychainValue(_ value: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            return SecItemAdd(item as CFDictionary, nil)
        }
        return updateStatus
    }

    private func deleteKeychainValue(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }

    private func updateOnMain(_ block: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            block()
        }
    }
}
