import Foundation

enum DownloadError: Error, LocalizedError {
    case permissionDenied
    case fileNotFound
    case writeFailed(Error)
    case invalidURL
    case downloadFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "下载权限被拒绝，请在设置中授权访问下载文件夹"
        case .fileNotFound:
            return "文件未找到"
        case .writeFailed(let error):
            return "写入文件失败: \(error.localizedDescription)"
        case .invalidURL:
            return "无效的下载地址"
        case .downloadFailed(let error):
            return "下载失败: \(error.localizedDescription)"
        }
    }
}
