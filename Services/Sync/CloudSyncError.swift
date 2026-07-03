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
            return "尚未选择同步文件夹"
        case .syncDirectoryNotFound:
            return "同步文件夹不存在"
        case .syncDirectoryNotWritable:
            return "同步文件夹不可写"
        case .syncDirectoryNotReadable:
            return "同步文件夹不可读"
        case .fileReadFailed(let path):
            return "文件读取失败: \(path)"
        case .fileWriteFailed(let path):
            return "文件写入失败: \(path)"
        case .fileHashFailed(let path):
            return "文件 HASH 计算失败: \(path)"
        case .fileCopyFailed(let source, let destination):
            return "文件拷贝失败: \(source) → \(destination)"
        case .metadataReadFailed:
            return "读取元数据失败"
        case .metadataWriteFailed:
            return "写入元数据失败"
        case .metadataCorrupted:
            return "元数据文件损坏"
        case .metadataVersionMismatch(let v):
            return "元数据版本不兼容：\(v)，请更新 WaifuX"
        case .manifestReadFailed:
            return "读取文件清单失败"
        case .manifestWriteFailed:
            return "写入文件清单失败"
        case .manifestCorrupted:
            return "文件清单损坏"
        case .syncInProgress:
            return "正在同步中，请等待完成"
        case .recordMergeFailed(let id, let reason):
            return "记录合并失败 [\(id)]: \(reason)"
        case .settingsMergeFailed(let reason):
            return "设置合并失败: \(reason)"
        case .profileMergeFailed(let reason):
            return "配置合并失败: \(reason)"
        case .webDAVConnectionFailed(let reason):
            return "WebDAV 连接失败: \(reason)"
        case .webDAVAuthenticationFailed:
            return "WebDAV 认证失败，请检查用户名和密码"
        case .webDAVNotAuthorized:
            return "WebDAV 权限不足"
        case .webDAVNotFound(let path):
            return "WebDAV 路径不存在: \(path)"
        case .webDAVProtocolError(let reason):
            return "WebDAV 协议错误: \(reason)"
        case .internalError(let reason):
            return "内部错误: \(reason)"
        case .cancelled:
            return "同步已取消"
        }
    }
}
