import Foundation

/// 同步过程中的错误类型
enum CloudSyncError: LocalizedError {
    // 配置错误
    case syncDirectoryNotSet
    case syncDirectoryNotFound
    case syncDirectoryNotWritable
    case syncDirectoryNotReadable

    // 文件操作错误
    case fileReadFailed(path: String)
    case fileWriteFailed(path: String)
    case fileHashFailed(path: String)
    case fileCopyFailed(source: String, destination: String)

    // 元数据错误
    case metadataReadFailed
    case metadataWriteFailed
    case metadataCorrupted
    case metadataVersionMismatch(version: Int)

    // Manifest 错误
    case manifestReadFailed
    case manifestWriteFailed
    case manifestCorrupted

    // 同步过程错误
    case syncInProgress
    case recordMergeFailed(id: String, reason: String)
    case settingsMergeFailed(reason: String)
    case profileMergeFailed(reason: String)

    // WebDAV 错误
    case webDAVConnectionFailed(reason: String)
    case webDAVAuthenticationFailed
    case webDAVNotAuthorized
    case webDAVNotFound(path: String)
    case webDAVProtocolError(reason: String)

    // 其他
    case internalError(reason: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .syncDirectoryNotSet:
            return t("尚未选择同步文件夹")
        case .syncDirectoryNotFound:
            return t("同步文件夹不存在")
        case .syncDirectoryNotWritable:
            return t("同步文件夹不可写")
        case .syncDirectoryNotReadable:
            return t("同步文件夹不可读")
        case .fileReadFailed(let path):
            return String(format: t("文件读取失败: %@"), String(describing: path))
        case .fileWriteFailed(let path):
            return String(format: t("文件写入失败: %@"), String(describing: path))
        case .fileHashFailed(let path):
            return String(format: t("文件 HASH 计算失败: %@"), String(describing: path))
        case .fileCopyFailed(let source, let destination):
            return String(format: t("文件拷贝失败: %@ → %@"), String(describing: source), String(describing: destination))
        case .metadataReadFailed:
            return t("读取元数据失败")
        case .metadataWriteFailed:
            return t("写入元数据失败")
        case .metadataCorrupted:
            return t("元数据文件损坏")
        case .metadataVersionMismatch(let v):
            return String(format: t("元数据版本不兼容：%@，请更新 WaifuX"), String(describing: v))
        case .manifestReadFailed:
            return t("读取文件清单失败")
        case .manifestWriteFailed:
            return t("写入文件清单失败")
        case .manifestCorrupted:
            return t("文件清单损坏")
        case .syncInProgress:
            return t("正在同步中，请等待完成")
        case .recordMergeFailed(let id, let reason):
            return String(format: t("记录合并失败 [%@]: %@"), String(describing: id), String(describing: reason))
        case .settingsMergeFailed(let reason):
            return String(format: t("设置合并失败: %@"), String(describing: reason))
        case .profileMergeFailed(let reason):
            return String(format: t("配置合并失败: %@"), String(describing: reason))
        case .webDAVConnectionFailed(let reason):
            return String(format: t("WebDAV 连接失败: %@"), String(describing: reason))
        case .webDAVAuthenticationFailed:
            return t("WebDAV 认证失败，请检查用户名和密码")
        case .webDAVNotAuthorized:
            return t("WebDAV 权限不足")
        case .webDAVNotFound(let path):
            return String(format: t("WebDAV 路径不存在: %@"), String(describing: path))
        case .webDAVProtocolError(let reason):
            return String(format: t("WebDAV 协议错误: %@"), String(describing: reason))
        case .internalError(let reason):
            return String(format: t("内部错误: %@"), String(describing: reason))
        case .cancelled:
            return t("同步已取消")
        }
    }
}
