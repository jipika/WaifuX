import Foundation

/// 库文件夹（支持壁纸和媒体两种内容类型）
struct LibraryFolder: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    let contentType: FolderContentType
    var parentFolderID: String?
    let createdAt: Date
    var updatedAt: Date
    
    init(
        id: String = UUID().uuidString,
        name: String,
        contentType: FolderContentType,
        parentFolderID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.parentFolderID = parentFolderID
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    enum FolderContentType: String, Codable, Hashable {
        case wallpaper
        case media
    }
}

// MARK: - 文件夹内项目（统一类型，用于 UI 展示）

enum LibraryItem: Identifiable, Hashable {
    case folder(LibraryFolder)
    case wallpaper(Wallpaper, downloadDate: Date?)
    case media(MediaItem, localFileURL: URL?)
    
    var id: String {
        switch self {
        case .folder(let folder): return "folder_\(folder.id)"
        case .wallpaper(let wallpaper, _): return wallpaper.id
        case .media(let media, _): return media.id
        }
    }
    
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
    
    var folder: LibraryFolder? {
        if case .folder(let f) = self { return f }
        return nil
    }
    
    var wallpaper: Wallpaper? {
        if case .wallpaper(let w, _) = self { return w }
        return nil
    }
    
    var mediaItem: MediaItem? {
        if case .media(let m, _) = self { return m }
        return nil
    }
}
