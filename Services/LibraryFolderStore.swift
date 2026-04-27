import Foundation
import Combine

/// 统一管理壁纸和媒体库的文件夹
@MainActor
final class LibraryFolderStore: ObservableObject {
    static let shared = LibraryFolderStore()
    
    @Published private(set) var wallpaperFolders: [LibraryFolder] = []
    @Published private(set) var mediaFolders: [LibraryFolder] = []
    
    private let defaults = UserDefaults.standard
    private let wallpaperFoldersKey = "library_wallpaper_folders_v1"
    private let mediaFoldersKey = "library_media_folders_v1"
    
    private init() {}
    
    // MARK: - 延迟恢复
    
    func restoreSavedData() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: wallpaperFoldersKey),
           let decoded = try? decoder.decode([LibraryFolder].self, from: data) {
            wallpaperFolders = decoded
        }
        if let data = defaults.data(forKey: mediaFoldersKey),
           let decoded = try? decoder.decode([LibraryFolder].self, from: data) {
            mediaFolders = decoded
        }
    }
    
    // MARK: - 查询
    
    func folders(for contentType: LibraryFolder.FolderContentType, parentID: String? = nil) -> [LibraryFolder] {
        let all = contentType == .wallpaper ? wallpaperFolders : mediaFolders
        return all.filter { $0.parentFolderID == parentID }
    }
    
    func folder(withID id: String, contentType: LibraryFolder.FolderContentType) -> LibraryFolder? {
        let all = contentType == .wallpaper ? wallpaperFolders : mediaFolders
        return all.first { $0.id == id }
    }
    
    func subfolders(of folderID: String, contentType: LibraryFolder.FolderContentType) -> [LibraryFolder] {
        let all = contentType == .wallpaper ? wallpaperFolders : mediaFolders
        return all.filter { $0.parentFolderID == folderID }
    }
    
    // MARK: - CRUD
    
    @discardableResult
    func createFolder(name: String, contentType: LibraryFolder.FolderContentType, parentID: String? = nil) -> LibraryFolder {
        let folder = LibraryFolder(name: name, contentType: contentType, parentFolderID: parentID)
        if contentType == .wallpaper {
            wallpaperFolders.append(folder)
            persistWallpaperFolders()
        } else {
            mediaFolders.append(folder)
            persistMediaFolders()
        }
        return folder
    }
    
    func renameFolder(id: String, contentType: LibraryFolder.FolderContentType, newName: String) {
        if contentType == .wallpaper {
            if let index = wallpaperFolders.firstIndex(where: { $0.id == id }) {
                wallpaperFolders[index].name = newName
                wallpaperFolders[index].updatedAt = Date()
                persistWallpaperFolders()
            }
        } else {
            if let index = mediaFolders.firstIndex(where: { $0.id == id }) {
                mediaFolders[index].name = newName
                mediaFolders[index].updatedAt = Date()
                persistMediaFolders()
            }
        }
    }
    
    func deleteFolder(id: String, contentType: LibraryFolder.FolderContentType) {
        // 先递归删除子文件夹
        let children = subfolders(of: id, contentType: contentType)
        for child in children {
            deleteFolder(id: child.id, contentType: contentType)
        }
        
        // 把该文件夹内所有项目的 folderID 置为 nil（移回根目录）
        if contentType == .wallpaper {
            WallpaperLibraryService.shared.moveItemsToRoot(fromFolder: id)
            wallpaperFolders.removeAll { $0.id == id }
            persistWallpaperFolders()
        } else {
            MediaLibraryService.shared.moveItemsToRoot(fromFolder: id)
            mediaFolders.removeAll { $0.id == id }
            persistMediaFolders()
        }
    }
    
    // MARK: - 移动
    
    func moveWallpaperToFolder(wallpaperID: String, folderID: String?) {
        WallpaperLibraryService.shared.moveWallpaperToFolder(wallpaperID: wallpaperID, folderID: folderID)
    }
    
    func moveMediaToFolder(mediaID: String, folderID: String?) {
        MediaLibraryService.shared.moveMediaToFolder(mediaID: mediaID, folderID: folderID)
    }
    
    // MARK: - 持久化
    
    private func persistWallpaperFolders() {
        if let data = try? JSONEncoder().encode(wallpaperFolders) {
            defaults.set(data, forKey: wallpaperFoldersKey)
        }
    }
    
    private func persistMediaFolders() {
        if let data = try? JSONEncoder().encode(mediaFolders) {
            defaults.set(data, forKey: mediaFoldersKey)
        }
    }
}
