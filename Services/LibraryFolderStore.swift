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
        // 注意：不要在这里 sanitize。
        // 启动时 MediaLibrary 比 FolderStore 更晚 restore；sanitize 由 App 在库数据都恢复后统一调用。
    }

    /// 启动时/同步后：把空字符串、孤儿、跨集合 folderID 清回根目录。
    func sanitizeLibraryFolderMemberships() {
        let wallpaperFavIDs = Set(
            wallpaperFolders
                .filter { $0.collection == .favorites }
                .map(\.id)
        )
        let wallpaperDlIDs = Set(
            wallpaperFolders
                .filter { $0.collection == .downloads }
                .map(\.id)
        )
        let mediaFavIDs = Set(
            mediaFolders
                .filter { $0.collection == .favorites }
                .map(\.id)
        )
        let mediaDlIDs = Set(
            mediaFolders
                .filter { $0.collection == .downloads }
                .map(\.id)
        )

        WallpaperLibraryService.shared.sanitizeFolderMembership(
            validFavoriteFolderIDs: wallpaperFavIDs,
            validDownloadFolderIDs: wallpaperDlIDs
        )
        MediaLibraryService.shared.sanitizeFolderMembership(
            validFavoriteFolderIDs: mediaFavIDs,
            validDownloadFolderIDs: mediaDlIDs
        )
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

    /// 查找或创建作者批量下载文件夹，保证同作者多次下载复用同一文件夹。
    ///
    /// 复用优先级：
    /// 1. 已下载作品上挂载的作者文件夹（按出现次数）
    /// 2. 下载集合中同名文件夹（忽略大小写/首尾空白，优先根目录）
    /// 3. 新建根目录文件夹
    @discardableResult
    func findOrCreateAuthorDownloadFolder(
        name: String,
        contentType: LibraryFolder.FolderContentType,
        identityKeys: Set<String> = []
    ) -> LibraryFolder {
        let preferredName = Self.normalizedFolderDisplayName(name)
        let normalizedPreferred = Self.normalizedFolderKey(preferredName)

        if let existing = resolveExistingAuthorDownloadFolder(
            preferredNameKey: normalizedPreferred,
            contentType: contentType,
            identityKeys: identityKeys
        ) {
            // 若历史上已拆成多个同名/同作者文件夹，把内容并回主文件夹
            consolidateAuthorDownloadFolders(
                into: existing,
                preferredNameKey: normalizedPreferred,
                contentType: contentType,
                identityKeys: identityKeys
            )
            return existing
        }

        return createFolder(
            name: preferredName,
            contentType: contentType,
            parentID: nil,
            collection: .downloads
        )
    }

    private func resolveExistingAuthorDownloadFolder(
        preferredNameKey: String,
        contentType: LibraryFolder.FolderContentType,
        identityKeys: Set<String>
    ) -> LibraryFolder? {
        let candidates = authorDownloadFolderCandidates(
            preferredNameKey: preferredNameKey,
            contentType: contentType,
            identityKeys: identityKeys
        )
        return candidates.first
    }

    /// 候选主文件夹：先按同作者占用次数，再按同名（根目录优先、更早创建优先）
    private func authorDownloadFolderCandidates(
        preferredNameKey: String,
        contentType: LibraryFolder.FolderContentType,
        identityKeys: Set<String>
    ) -> [LibraryFolder] {
        let allFolders = contentType == .wallpaper ? wallpaperFolders : mediaFolders
        let downloadFolders = allFolders.filter { $0.collection == .downloads }
        guard !downloadFolders.isEmpty else { return [] }

        let folderByID = Dictionary(uniqueKeysWithValues: downloadFolders.map { ($0.id, $0) })
        var usageCount: [String: Int] = [:]

        if !identityKeys.isEmpty {
            switch contentType {
            case .wallpaper:
                for record in WallpaperLibraryService.shared.downloadedWallpapers {
                    guard let folderID = record.folderID, folderByID[folderID] != nil else { continue }
                    let keys = Self.wallpaperAuthorIdentityKeys(record.wallpaper)
                    guard !keys.isDisjoint(with: identityKeys) else { continue }
                    usageCount[folderID, default: 0] += 1
                }
            case .media:
                for record in MediaLibraryService.shared.downloadedItems {
                    guard let folderID = record.folderID, folderByID[folderID] != nil else { continue }
                    let keys = Self.mediaAuthorIdentityKeys(record.item)
                    guard !keys.isDisjoint(with: identityKeys) else { continue }
                    usageCount[folderID, default: 0] += 1
                }
            }
        }

        let nameMatches = downloadFolders.filter {
            Self.normalizedFolderKey($0.name) == preferredNameKey
        }

        var ordered: [LibraryFolder] = []
        var seen = Set<String>()

        let identityOrdered = usageCount.keys
            .compactMap { folderByID[$0] }
            .sorted { lhs, rhs in
                let lhsCount = usageCount[lhs.id, default: 0]
                let rhsCount = usageCount[rhs.id, default: 0]
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs.createdAt < rhs.createdAt
            }
        for folder in identityOrdered where seen.insert(folder.id).inserted {
            ordered.append(folder)
        }

        let nameOrdered = nameMatches.sorted { lhs, rhs in
            let lhsRoot = lhs.parentFolderID == nil
            let rhsRoot = rhs.parentFolderID == nil
            if lhsRoot != rhsRoot { return lhsRoot && !rhsRoot }
            return lhs.createdAt < rhs.createdAt
        }
        for folder in nameOrdered where seen.insert(folder.id).inserted {
            ordered.append(folder)
        }

        return ordered
    }

    /// 把同名/同作者的多余文件夹内容合并进主文件夹，并删除空的重复文件夹
    private func consolidateAuthorDownloadFolders(
        into primary: LibraryFolder,
        preferredNameKey: String,
        contentType: LibraryFolder.FolderContentType,
        identityKeys: Set<String>
    ) {
        let duplicates = authorDownloadFolderCandidates(
            preferredNameKey: preferredNameKey,
            contentType: contentType,
            identityKeys: identityKeys
        ).filter { $0.id != primary.id }

        guard !duplicates.isEmpty else { return }

        for duplicate in duplicates {
            switch contentType {
            case .wallpaper:
                let records = WallpaperLibraryService.shared.downloadedWallpapers(inFolder: duplicate.id)
                for record in records {
                    moveWallpaperToFolder(
                        wallpaperID: record.wallpaper.id,
                        folderID: primary.id,
                        scope: .downloads
                    )
                }
            case .media:
                let records = MediaLibraryService.shared.downloadedItems(inFolder: duplicate.id)
                for record in records {
                    moveMediaToFolder(
                        mediaID: record.item.id,
                        folderID: primary.id,
                        scope: .downloads
                    )
                }
            }

            // 仅删除已无内容的重复作者文件夹，避免误删用户手建且仍有内容的目录
            let remaining: Int
            switch contentType {
            case .wallpaper:
                remaining = WallpaperLibraryService.shared.downloadedWallpapers(inFolder: duplicate.id).count
                    + WallpaperLibraryService.shared.favoriteWallpapers(inFolder: duplicate.id).count
                    + subfolders(of: duplicate.id, contentType: .wallpaper).count
            case .media:
                remaining = MediaLibraryService.shared.downloadedItems(inFolder: duplicate.id).count
                    + MediaLibraryService.shared.favoriteItems(inFolder: duplicate.id).count
                    + subfolders(of: duplicate.id, contentType: .media).count
            }
            if remaining == 0 {
                deleteFolder(id: duplicate.id, contentType: contentType)
            }
        }
    }

    static func wallpaperAuthorIdentityKeys(_ wallpaper: Wallpaper) -> Set<String> {
        var keys = Set<String>()
        if let pixivID = wallpaper.pixivAuthorID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pixivID.isEmpty {
            keys.insert("pixiv:\(pixivID)")
        }
        if let username = wallpaper.uploader?.username
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !username.isEmpty {
            keys.insert("name:\(username.lowercased())")
        }
        return keys
    }

    static func mediaAuthorIdentityKeys(_ item: MediaItem) -> Set<String> {
        var keys = Set<String>()
        if let steamID = item.authorSteamID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !steamID.isEmpty {
            keys.insert("steam:\(steamID)")
        }
        if let name = item.authorName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            keys.insert("name:\(name.lowercased())")
        }
        return keys
    }

    static func normalizedFolderDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    static func normalizedFolderKey(_ name: String) -> String {
        normalizedFolderDisplayName(name).lowercased()
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
        scope: WallpaperLibraryService.FolderMembershipScope,
        fallback: (wallpaper: Wallpaper, fileURL: URL)? = nil
    ) {
        WallpaperLibraryService.shared.moveWallpaperToFolder(
            wallpaperID: wallpaperID,
            folderID: folderID,
            scope: scope,
            fallback: fallback
        )
    }

    func moveMediaToFolder(
        mediaID: String,
        folderID: String?,
        scope: MediaLibraryService.FolderMembershipScope,
        fallback: (item: MediaItem, fileURL: URL)? = nil
    ) {
        MediaLibraryService.shared.moveMediaToFolder(
            mediaID: mediaID,
            folderID: folderID,
            scope: scope,
            fallback: fallback
        )
    }

    // MARK: - 云同步

    /// 同步导入壁纸文件夹（云同步使用）。
    /// 按 folder.id 合并，而不是整表替换，避免云端旧快照抹掉本地新建文件夹。
    func syncImportWallpaperFolders(_ folders: [LibraryFolder]) {
        wallpaperFolders = Self.mergeFolders(local: wallpaperFolders, remote: folders)
        persistWallpaperFolders()
        sanitizeLibraryFolderMemberships()
    }

    /// 同步导入媒体文件夹（云同步使用）。按 folder.id 合并。
    func syncImportMediaFolders(_ folders: [LibraryFolder]) {
        mediaFolders = Self.mergeFolders(local: mediaFolders, remote: folders)
        persistMediaFolders()
        sanitizeLibraryFolderMemberships()
    }

    /// 以 id 为键合并文件夹：同 id 取 updatedAt 更新者；云端有而本地没有的补入；本地独有的保留。
    private static func mergeFolders(local: [LibraryFolder], remote: [LibraryFolder]) -> [LibraryFolder] {
        var byID: [String: LibraryFolder] = Dictionary(
            local.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        for remoteFolder in remote {
            if let existing = byID[remoteFolder.id] {
                if remoteFolder.updatedAt >= existing.updatedAt {
                    byID[remoteFolder.id] = remoteFolder
                }
            } else {
                byID[remoteFolder.id] = remoteFolder
            }
        }
        return byID.values.sorted { $0.createdAt < $1.createdAt }
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
