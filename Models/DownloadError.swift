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
            return "无法在应用数据目录保存文件（通常位于「资源库 → 应用程序支持 → WaifuX」）。请检查磁盘空间与文件夹权限。"
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
