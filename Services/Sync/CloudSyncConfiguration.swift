import Foundation
import Combine

@MainActor
final class CloudSyncConfiguration: ObservableObject {
    static let shared = CloudSyncConfiguration()

    // MARK: - Published 属性（自动持久化到 UserDefaults）
    @Published var isEnabled: Bool = false {
        didSet { save() }
    }

    @Published var syncMode: CloudSyncMode = .localFolder {
        didSet { save() }
    }

    @Published var syncDirectoryURL: URL? {
        didSet {
            if let url = syncDirectoryURL {
                // 存储 bookmark 以支持安全范围访问
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    UserDefaults.standard.set(bookmarkData, forKey: Self.syncDirectoryBookmarkKey)
                    UserDefaults.standard.set(url.path, forKey: Self.syncDirectoryPathKey)
                } catch {
                    // 存储路径作为 fallback
                    UserDefaults.standard.set(url.path, forKey: Self.syncDirectoryPathKey)
                }
            } else {
                UserDefaults.standard.removeObject(forKey: Self.syncDirectoryBookmarkKey)
                UserDefaults.standard.removeObject(forKey: Self.syncDirectoryPathKey)
            }
        }
    }

    // WebDAV 配置
    @Published var webDAVURLString: String = "" {
        didSet { save() }
    }

    @Published var webDAVUsername: String = "" {
        didSet { save() }
    }

    @Published var webDAVPassword: String = "" {
        didSet { save() }
    }

    @Published var conflictStrategy: CloudSyncConflictStrategy = .localPreferred {
        didSet { save() }
    }

    @Published var lastSyncedAt: Date? {
        didSet { save() }
    }

    // MARK: - UserDefaults Keys
    private static let isEnabledKey = "cloud_sync_enabled"
    private static let syncModeKey = "cloud_sync_mode"
    private static let conflictStrategyKey = "cloud_sync_conflict_strategy"
    private static let lastSyncedAtKey = "cloud_sync_last_synced_at"
    private static let syncDirectoryBookmarkKey = "cloud_sync_directory_bookmark"
    private static let syncDirectoryPathKey = "cloud_sync_directory_path"
    private static let webDAVURLKey = "cloud_sync_webdav_url"
    private static let webDAVUsernameKey = "cloud_sync_webdav_username"
    private static let webDAVPasswordKey = "cloud_sync_webdav_password"

    /// WebDAV 凭证（组合 URL + 用户名 + 密码）
    var webDAVCredentials: WebDAVCredentials? {
        guard syncMode == .webDAV,
              let url = URL(string: webDAVURLString),
              !webDAVUsername.isEmpty,
              !webDAVPassword.isEmpty else {
            return nil
        }
        return WebDAVCredentials(
            baseURL: url,
            username: webDAVUsername,
            password: webDAVPassword
        )
    }

    // MARK: - 计算属性
    var syncRootURL: URL? {
        guard syncMode == .localFolder, let dir = syncDirectoryURL else { return nil }
        return dir.appendingPathComponent(CloudSyncDirectoryLayout.rootName)
            .appendingPathComponent(CloudSyncDirectoryLayout.versionDir)
    }

    var metadataURL: URL? {
        syncRootURL?.appendingPathComponent(CloudSyncDirectoryLayout.metadataFileName)
    }

    var manifestURL: URL? {
        syncRootURL?.appendingPathComponent(CloudSyncDirectoryLayout.manifestFileName)
    }

    var objectsURL: URL? {
        syncRootURL?.appendingPathComponent(CloudSyncDirectoryLayout.objectsDirName)
    }

    // MARK: - 初始化
    private init() {
        load()
    }

    // MARK: - 持久化
    private func save() {
        UserDefaults.standard.set(isEnabled, forKey: Self.isEnabledKey)
        UserDefaults.standard.set(syncMode.rawValue, forKey: Self.syncModeKey)
        UserDefaults.standard.set(conflictStrategy.rawValue, forKey: Self.conflictStrategyKey)
        if let lastSyncedAt {
            UserDefaults.standard.set(lastSyncedAt.timeIntervalSince1970, forKey: Self.lastSyncedAtKey)
        }
        UserDefaults.standard.set(webDAVURLString, forKey: Self.webDAVURLKey)
        UserDefaults.standard.set(webDAVUsername, forKey: Self.webDAVUsernameKey)
        UserDefaults.standard.set(webDAVPassword, forKey: Self.webDAVPasswordKey)
    }

    private func load() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledKey)
        if let modeRaw = UserDefaults.standard.string(forKey: Self.syncModeKey),
           let mode = CloudSyncMode(rawValue: modeRaw) {
            syncMode = mode
        }
        if let strategyRaw = UserDefaults.standard.string(forKey: Self.conflictStrategyKey),
           let strategy = CloudSyncConflictStrategy(rawValue: strategyRaw) {
            conflictStrategy = strategy
        }
        if let timestamp = UserDefaults.standard.object(forKey: Self.lastSyncedAtKey) as? TimeInterval {
            lastSyncedAt = Date(timeIntervalSince1970: timestamp)
        }
        webDAVURLString = UserDefaults.standard.string(forKey: Self.webDAVURLKey) ?? ""
        webDAVUsername = UserDefaults.standard.string(forKey: Self.webDAVUsernameKey) ?? ""
        webDAVPassword = UserDefaults.standard.string(forKey: Self.webDAVPasswordKey) ?? ""
        // 恢复目录 URL
        if let bookmarkData = UserDefaults.standard.data(forKey: Self.syncDirectoryBookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                syncDirectoryURL = url
                return
            }
        }
        if let path = UserDefaults.standard.string(forKey: Self.syncDirectoryPathKey) {
            syncDirectoryURL = URL(fileURLWithPath: path)
        }
    }

    // MARK: - 清除配置
    func reset() {
        isEnabled = false
        syncMode = .localFolder
        syncDirectoryURL = nil
        conflictStrategy = .localPreferred
        lastSyncedAt = nil
        webDAVURLString = ""
        webDAVUsername = ""
        webDAVPassword = ""
    }
}
