import Foundation

// MARK: - 同步模式
enum CloudSyncMode: String, Codable, CaseIterable {
    /// 本地文件夹模式（iCloud/Dropbox/SMB 挂载）
    case localFolder
    /// WebDAV 远程服务器模式
    case webDAV
}

// MARK: - 冲突策略
enum CloudSyncConflictStrategy: String, Codable, CaseIterable {
    case localPreferred   // 本地方优先（默认）
    case cloudPreferred   // 云端优先

    var displayName: String {
        switch self {
        case .localPreferred: return "本地方优先"
        case .cloudPreferred: return "云端优先"
        }
    }
}

// MARK: - Manifest（文件清单）
struct CloudSyncManifest: Codable {
    var version: Int = 1
    var files: [String: CloudSyncManifestEntry]  // 相对路径 → 条目
    var updatedAt: Date

    struct CloudSyncManifestEntry: Codable {
        let hash: String          // SHA-256 hex
        let size: Int64
        let mtime: Date
    }
}

// MARK: - 同步目录结构定义
enum CloudSyncDirectoryLayout {
    static let rootName = "WaifuXSync"
    static let versionDir = "v1"
    static let metadataFileName = "metadata.json"
    static let manifestFileName = "manifest.json"
    static let objectsDirName = "objects"

    /// 计算某个 hash 对应的 objects 子目录
    static func objectSubpath(hash: String) -> String {
        let prefix = String(hash.prefix(2))
        return "\(objectsDirName)/\(prefix)/\(hash)"
    }
}
