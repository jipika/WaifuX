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

    func folders(for contentType: LibraryFolder.FolderContentType, parentID: String? = nil, collection: LibraryFolder.FolderCollection? = nil) -> [LibraryFolder] {
        let all = contentType == .wallpaper ? wallpaperFolders : mediaFolders
        return all.filter { folder in
            guard folder.parentFolderID == parentID else { return false }
            if let collection {
                return folder.collection == collection
            }
            return true
        }
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
    func createFolder(name: String, contentType: LibraryFolder.FolderContentType, parentID: String? = nil, collection: LibraryFolder.FolderCollection = .downloads) -> LibraryFolder {
        let folder = LibraryFolder(name: name, contentType: contentType, parentFolderID: parentID, collection: collection)
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

    // MARK: - 加密锁定

    /// 切换文件夹加密状态（锁定/取消锁定）
    func toggleFolderLock(id: String, contentType: LibraryFolder.FolderContentType) {
        if contentType == .wallpaper {
            guard let index = wallpaperFolders.firstIndex(where: { $0.id == id }) else { return }
            wallpaperFolders[index].isLocked.toggle()
            wallpaperFolders[index].updatedAt = Date()
            persistWallpaperFolders()
        } else {
            guard let index = mediaFolders.firstIndex(where: { $0.id == id }) else { return }
            mediaFolders[index].isLocked.toggle()
            mediaFolders[index].updatedAt = Date()
            persistMediaFolders()
        }
        // 如果取消加密，从解锁集合中移除
        if folder(withID: id, contentType: contentType)?.isLocked == false {
            FolderLockService.shared.lockFolder(id)
        }
    }

    /// 设置文件夹加密状态
    func setFolderLock(id: String, contentType: LibraryFolder.FolderContentType, locked: Bool) {
        if contentType == .wallpaper {
            guard let index = wallpaperFolders.firstIndex(where: { $0.id == id }) else { return }
            wallpaperFolders[index].isLocked = locked
            wallpaperFolders[index].updatedAt = Date()
            persistWallpaperFolders()
        } else {
            guard let index = mediaFolders.firstIndex(where: { $0.id == id }) else { return }
            mediaFolders[index].isLocked = locked
            mediaFolders[index].updatedAt = Date()
            persistMediaFolders()
        }
        if !locked {
            FolderLockService.shared.lockFolder(id)
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

    func moveWallpaperToFolder(
        wallpaperID: String,
        folderID: String?,
        fallback: (wallpaper: Wallpaper, fileURL: URL)? = nil
    ) {
        WallpaperLibraryService.shared.moveWallpaperToFolder(
            wallpaperID: wallpaperID,
            folderID: folderID,
            fallback: fallback
        )
    }

    func moveMediaToFolder(
        mediaID: String,
        folderID: String?,
        fallback: (item: MediaItem, fileURL: URL)? = nil
    ) {
        MediaLibraryService.shared.moveMediaToFolder(
            mediaID: mediaID,
            folderID: folderID,
            fallback: fallback
        )
    }

    // MARK: - 云同步

    /// 同步导入壁纸文件夹（云同步使用）
    func syncImportWallpaperFolders(_ folders: [LibraryFolder]) {
        wallpaperFolders = folders
        persistWallpaperFolders()
    }

    /// 同步导入媒体文件夹（云同步使用）
    func syncImportMediaFolders(_ folders: [LibraryFolder]) {
        mediaFolders = folders
        persistMediaFolders()
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

// MARK: - 本地库网格排序

enum LibraryGridContentKind: String, Codable, Hashable {
    case wallpaper
    case media
}

enum LibraryGridCollectionKind: String, Codable, Hashable {
    case favorites
    case downloads
}

struct LibraryGridOrderScope: Hashable {
    let content: LibraryGridContentKind
    let collection: LibraryGridCollectionKind
    let parentFolderID: String?

    var storageKey: String {
        [
            content.rawValue,
            collection.rawValue,
            parentFolderID ?? "root"
        ].joined(separator: ".")
    }
}

@MainActor
final class LibraryGridOrderStore: ObservableObject {
    static let shared = LibraryGridOrderStore()

    @Published private(set) var revision = 0

    private let defaults = UserDefaults.standard
    private let orderKey = "library_grid_order_v1"
    private var orders: [String: [String]] = [:]

    private init() {
        if let data = defaults.data(forKey: orderKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            orders = decoded
        }
    }

    func orderedIDs(for ids: [String], scope: LibraryGridOrderScope) -> [String] {
        let available = Set(ids)
        let saved = orders[scope.storageKey] ?? []
        let orderedSaved = saved.filter { available.contains($0) }
        let newIDs = ids.filter { !orderedSaved.contains($0) }
        let newFolderIDs = newIDs.filter { $0.hasPrefix("folder_") }
        let newItemIDs = newIDs.filter { !$0.hasPrefix("folder_") }

        var ordered = newFolderIDs + orderedSaved
        let insertIndex = ordered.lastIndex { $0.hasPrefix("folder_") }.map { ordered.index(after: $0) } ?? ordered.startIndex
        ordered.insert(contentsOf: newItemIDs, at: insertIndex)
        return ordered
    }

    func reorder(moving movingIDs: [String], before targetID: String?, availableIDs: [String], scope: LibraryGridOrderScope) {
        let available = Set(availableIDs)
        let moving = movingIDs.filter { available.contains($0) }
        guard !moving.isEmpty else { return }
        if let targetID {
            guard available.contains(targetID), !moving.contains(targetID) else { return }
        }

        var next = orderedIDs(for: availableIDs, scope: scope)
        next.removeAll { moving.contains($0) }

        let insertIndex: Int
        if let targetID, let index = next.firstIndex(of: targetID) {
            insertIndex = index
        } else {
            insertIndex = next.endIndex
        }
        next.insert(contentsOf: moving, at: insertIndex)

        orders[scope.storageKey] = next
        persist()
    }

    func removeIDs(_ ids: Set<String>, from scope: LibraryGridOrderScope) {
        guard !ids.isEmpty, var saved = orders[scope.storageKey] else { return }
        saved.removeAll { ids.contains($0) }
        orders[scope.storageKey] = saved
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(orders) {
            defaults.set(data, forKey: orderKey)
        }
        revision += 1
    }

    // MARK: - 云同步

    /// 导出全部排序数据（云同步使用）
    func exportOrders() -> [String: [String]] {
        return orders
    }

    /// 同步导入排序数据（云同步使用）
    func syncImportOrders(_ newOrders: [String: [String]]) {
        orders = newOrders
        persist()
    }
}
