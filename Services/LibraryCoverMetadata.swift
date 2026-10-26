import Foundation
import AppKit

// MARK: - 我的库封面元数据（解析结果复用，避免重复扫 Workshop 目录）
//
// 背景（2026-10-26 诊断）：当前媒体库 250 条活跃记录里 220 个是 Wallpaper Engine 工程
// 目录。`AnyMediaItem.init` → `libraryGridThumbnailURL` 在主线程逐条解析封面，目录型
// 条目要查内部视频与 preview；文件夹叠图与可见 cell 又会重复解析同一工程。
// 本 store 只做一件事：把「工程目录 → 封面文件」的解析结果按记录复用。
//
// 契约（积极结果）：
// - 只有解析出**确在磁盘上的本地封面文件**才落库；远程元数据兜底（站点 thumb/poster）
//   不进缓存 —— 避免把「暂时没有本地封面」钉死，后续烘焙/抽帧升级后还能自然接管。
// - 落库条目带封面文件的 mtime+size 签名；同路径文件被替换（重烘焙/重下载）后签名
//   失配自动失效，不会长期返回旧封面。字节级相同替换由签名窗口兜底（见 matches）。
// - Workshop 目录解析（contentsOfDirectory / project.json）在专用 actor 上执行，
//   并发上限 2，防止外置卷 I/O 风暴；同一 key 的并发请求单飞合并。
// - 单写者 + 原子写持久化到 ~/Library/Caches/WaifuX，与 LocalImageThumbnails 同根，
//   用户清缓存即整体重置，重跑一轮命中短路代价小。
//
// 隔离边界：仅主 App（WaifuX target）编译。Helper target 的显式源清单不含本文件，
// BackgroundAgent/ 与 Models/MediaItem+LocalFiles.swift 均不引用本类型 —— 回归脚本
// Tests/LibraryCoverMetadataRegression.swift 以源码断言钉住这条边界。

/// 封面来源文件的 mtime+size 签名。是「这次解析时文件是什么」，不是终身有效声明。
struct LibraryCoverFileSignature: Codable, Hashable, Sendable {
    let modificationTime: TimeInterval
    let size: UInt64

    init?(url: URL) {
        // 必须用 attributesOfItem：URL.resourceValues(forKeys:) 在同一进程内带缓存，
        // 同路径删除+重写后会读到旧 size/mtime（回归脚本实测），导致同路径替换不失效。
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        modificationTime = date.timeIntervalSince1970
        self.size = size
    }

    /// 签名匹配容差：mtime 比较放宽到 1s，覆盖 FAT 等卷 2s 粒度的时钟戳；
    /// size 必须精确相等。size 相同但内容不同的极端替换（重编码同大小）由
    /// 60s TTL 窗口兜底 —— TTL 过期后重查签名，仍一致才继续命中。
    static func matches(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.size == rhs.size && abs(lhs.modificationTime - rhs.modificationTime) <= 1.0
    }
}

/// 一条解析结果：确定的封面文件 + 该记录当前的视频文件解析（供卡片直用）。
struct LibraryCoverMetadata: Codable, Hashable, Sendable {
    let thumbnailURL: URL
    let resolvedVideoFileURL: URL?
    let bakedAt: Date
    /// 封面文件的签名；校验失败即整条失效。
    let sourceSignature: LibraryCoverFileSignature

    init(thumbnailURL: URL, resolvedVideoFileURL: URL?, sourceSignature: LibraryCoverFileSignature) {
        self.thumbnailURL = thumbnailURL
        self.resolvedVideoFileURL = resolvedVideoFileURL
        self.bakedAt = Date()
        self.sourceSignature = sourceSignature
    }

    var isFresh: Bool {
        Date().timeIntervalSince(bakedAt) < Self.ttl
    }

    static let ttl: TimeInterval = 60
}

/// 解析工作本体。在后台 actor 上执行；不触碰 Kingfisher、不抽帧、不下载，
/// 只读已有磁盘缓存与工程目录结构（与 MediaItem.libraryGridThumbnailURL 的
/// 优先级链一致，但只取「本地文件已存在」的积极结果）。
actor LibraryCoverMetadataResolver {
    static let shared = LibraryCoverMetadataResolver()

    private static let maxConcurrent = 2
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<LibraryCoverMetadata?, Never>] = [:]

    private func acquireSlot() async {
        if active < Self.maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseSlot() {
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }

    func resolve(
        item: MediaItem,
        localFileURL: URL?,
        bakedVideoPath: String?,
        itemID: String
    ) async -> LibraryCoverMetadata? {
        let key = [itemID, localFileURL?.standardizedFileURL.path ?? "", bakedVideoPath ?? ""].joined(separator: "|")
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task.detached(priority: .utility) {
            await Self.performResolve(
                item: item,
                localFileURL: localFileURL,
                bakedVideoPath: bakedVideoPath,
                itemID: itemID
            )
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    /// 纯解析逻辑，static 便于回归脚本直接编译验证。优先级对齐
    /// MediaItem.libraryGridThumbnailURL：烘焙列表帧 > 烘焙 poster > 实时静帧 >
    /// 本地静图 SSD 小图 > 本地静图原图（512 由 Kingfisher 降采样兜底）>
    /// 工程内视频已有抽帧 > 工程 preview。
    nonisolated static func performResolve(
        item: MediaItem,
        localFileURL: URL?,
        bakedVideoPath: String?,
        itemID: String
    ) async -> LibraryCoverMetadata? {
        func signatured(_ url: URL, video: URL?) -> LibraryCoverMetadata? {
            guard let signature = LibraryCoverFileSignature(url: url) else { return nil }
            return LibraryCoverMetadata(
                thumbnailURL: url,
                resolvedVideoFileURL: video,
                sourceSignature: signature
            )
        }

        // 1. Scene 烘焙产物：列表帧优先，高清 poster 兜底（poster 有 letterbox 裁切）
        // 三个缓存单例均隔离在 MainActor（VideoThumbnailCache/LocalImageThumbnailCache）
        // 或自身线程安全（FileExistenceCache）：MainActor 的两条 await 进 actor 域调用，
        // FileExistenceCache 直接读。
        if let bakedVideoPath, !bakedVideoPath.isEmpty {
            let bakedURL = URL(fileURLWithPath: bakedVideoPath)
            if let listThumb = await VideoThumbnailCache.shared.cachedListThumbnailFileURLIfExists(forLocalVideo: bakedURL),
               let result = signatured(listThumb, video: bakedURL) { return result }
            if let poster = await VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: itemID),
               let result = signatured(poster, video: bakedURL) { return result }
        }

        // 2. 本地静图：SSD 列表小图优先，原图兜底（不触发生成）
        if let localFileURL, localFileURL.isFileURL,
           LocalImageThumbnailCache.isRasterImageFile(localFileURL) {
            if let cached = await LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: localFileURL),
               let result = signatured(cached, video: nil) { return result }
            if FileManager.default.fileExists(atPath: localFileURL.path),
               let result = signatured(localFileURL, video: nil) { return result }
        }

        // 3. Workshop 工程目录：内部视频的已有抽帧，其次 preview 图
        if let localFileURL, localFileURL.isFileURL,
           FileExistenceCache.shared.isDirectory(atPath: localFileURL.path) {
            if let video = MediaItem.resolveLocalVideoFile(from: localFileURL) {
                if let listThumb = await VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: video),
                   let result = signatured(listThumb, video: video) { return result }
                if let poster = await VideoThumbnailCache.shared.cachedPosterJPEGFileURLIfExists(forLocalVideo: video),
                   let result = signatured(poster, video: video) { return result }
            }
            if let preview = MediaItem.resolveLocalWorkshopPreviewImage(from: localFileURL) {
                if let cached = await LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: preview),
                   let result = signatured(cached, video: nil) { return result }
                if let result = signatured(preview, video: nil) { return result }
            }
        }

        // 4. 直出视频文件：已有抽帧
        if let localFileURL, localFileURL.isFileURL,
           ["mp4", "mov", "webm", "m4v", "mkv"].contains(localFileURL.pathExtension.lowercased()) {
            if let listThumb = await VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: localFileURL),
               let result = signatured(listThumb, video: localFileURL) { return result }
            if let poster = await VideoThumbnailCache.shared.cachedPosterJPEGFileURLIfExists(forLocalVideo: localFileURL),
               let result = signatured(poster, video: localFileURL) { return result }
        }

        // 无本地积极结果（远程兜底 / 完全没有封面文件）：不落库
        return nil
    }
}

/// 主线程门面：库页与 cell 只与这个类型交互。
/// 命中校验 = 签名匹配 + TTL；失效条目静默清除并走一次后台重解析。
@MainActor
final class LibraryCoverMetadataStore {
    static let shared = LibraryCoverMetadataStore()

    struct RequestKey: Hashable {
        let itemID: String
        let localPath: String?
        let bakedVideoPath: String?

        /// 持久化字典的扁平键：与 disk 条目一一对应
        var storageKey: String {
            [itemID, localPath ?? "", bakedVideoPath ?? ""].joined(separator: "|")
        }
    }

    private struct DiskEntry: Codable {
        let key: String
        let metadata: LibraryCoverMetadata
    }

    private var memory: [RequestKey: LibraryCoverMetadata] = [:]
    private var persisted: [String: LibraryCoverMetadata] = [:]
    private var pending: Set<RequestKey> = []
    private var loaded = false
    private var dirty = false
    private var flushTask: Task<Void, Never>?
    /// 封面元数据就绪（新解析落库）时递增；库页消费后归零。
    /// 与 libraryContentRevision 分开，避免每张封面就绪都触发全列表重建。
    private(set) var contentRevision: UInt = 0
    private let maxPersistedEntries = 4096
    private static let flushDelayNanoseconds: UInt64 = 350_000_000

    private var storeURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaifuX/LibraryCoverMetadata-v1.json")
    }

    private init() {}

    // MARK: - 查询

    /// 只读命中（不触发解析）。网格构建热路径用这个：命中直接用，未命中保持原有封面。
    func cachedMetadata(
        itemID: String,
        localFileURL: URL?,
        bakedVideoPath: String?
    ) -> LibraryCoverMetadata? {
        loadIfNeeded()
        let key = makeKey(itemID: itemID, localFileURL: localFileURL, bakedVideoPath: bakedVideoPath)
        guard let metadata = memory[key] ?? persisted[key.storageKey] else { return nil }
        guard metadata.isFresh,
              let signature = LibraryCoverFileSignature(url: metadata.thumbnailURL),
              LibraryCoverFileSignature.matches(signature, metadata.sourceSignature) else {
            memory.removeValue(forKey: key)
            if persisted.removeValue(forKey: key.storageKey) != nil { scheduleFlush() }
            return nil
        }
        memory[key] = metadata
        return metadata
    }

    /// 命中即回；未命中排一次后台解析，完成回调一次（成功或 nil 都回调）。
    /// 同一 key 的并发请求合并成一次解析。
    func resolveMetadata(
        itemID: String,
        item: MediaItem,
        localFileURL: URL?,
        bakedVideoPath: String?,
        completion: @escaping @MainActor (LibraryCoverMetadata?) -> Void
    ) {
        loadIfNeeded()
        if let cached = cachedMetadata(
            itemID: itemID,
            localFileURL: localFileURL,
            bakedVideoPath: bakedVideoPath
        ) {
            completion(cached)
            return
        }
        let key = makeKey(itemID: itemID, localFileURL: localFileURL, bakedVideoPath: bakedVideoPath)
        guard !pending.contains(key) else { return }
        pending.insert(key)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await LibraryCoverMetadataResolver.shared.resolve(
                item: item,
                localFileURL: localFileURL,
                bakedVideoPath: bakedVideoPath,
                itemID: itemID
            )
            self.pending.remove(key)
            guard !Task.isCancelled else { return }
            if let resolved {
                self.memory[key] = resolved
                self.persisted[key.storageKey] = resolved
                self.trimPersistedIfNeeded()
                self.scheduleFlush()
                self.contentRevision &+= 1
            }
            completion(resolved)
        }
    }

    // MARK: - 失效

    /// 记录级失效：删除/重下载/烘焙产物变化/移动后调用。
    func invalidate(itemID: String) {
        memory = memory.filter { $0.key.itemID != itemID }
        let prefix = itemID + "|"
        let removed = persisted.keys.filter { $0.hasPrefix(prefix) }
        guard !removed.isEmpty else { return }
        removed.forEach { persisted.removeValue(forKey: $0) }
        scheduleFlush()
    }

    /// 全量失效：目录迁移（bulkUpdateDownloadPaths）后调用。
    func invalidateAll() {
        memory.removeAll()
        guard !persisted.isEmpty else { return }
        persisted.removeAll()
        scheduleFlush()
    }

    func clearMemory() {
        memory.removeAll()
    }

    /// 供内存压力路径调用：清内存、标记 TTL 过期（磁盘条目下次查询时重验签名）。
    func handleMemoryPressure() {
        clearMemory()
    }

    func consumeContentRevision() -> UInt {
        let value = contentRevision
        contentRevision = 0
        return value
    }

    // MARK: - 持久化（单写者 + 原子写）

    private func makeKey(itemID: String, localFileURL: URL?, bakedVideoPath: String?) -> RequestKey {
        RequestKey(
            itemID: itemID,
            localPath: localFileURL?.standardizedFileURL.path,
            bakedVideoPath: bakedVideoPath
        )
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL),
              let entries = try? JSONDecoder().decode([DiskEntry].self, from: data) else { return }
        persisted = Dictionary(
            entries.map { ($0.key, $0.metadata) },
            uniquingKeysWith: { _, newer in newer }
        )
    }

    private func trimPersistedIfNeeded() {
        guard persisted.count > maxPersistedEntries else { return }
        // 按 bakedAt 升序淘汰最旧的一批，一次砍到上限的 3/4，避免频繁重写
        let sorted = persisted.sorted { $0.value.bakedAt < $1.value.bakedAt }
        let excess = persisted.count - (maxPersistedEntries * 3 / 4)
        for (key, _) in sorted.prefix(excess) {
            persisted.removeValue(forKey: key)
        }
    }

    private func scheduleFlush() {
        dirty = true
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushDelayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.writeSnapshot()
        }
    }

    private func writeSnapshot() {
        guard dirty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(
            persisted.sorted { $0.key < $1.key }.map { DiskEntry(key: $0.key, metadata: $0.value) }
        ) else { return }
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: .atomic)
            dirty = false
        } catch {
            // 保留 dirty，下次变更时重试；读路径不受影响（内存是权威）
        }
    }
}

// MARK: - MediaItem 便捷入口（仅主 App；本文件不在 Helper 的显式源清单内）

extension MediaItem {
    /// 库网格轻量封面：命中解析缓存直接用；未命中返回 nil，调用方保留原有
    /// 元数据封面（coverImageURL / 站点 thumb），由 store 后台补齐后经
    /// contentRevision 通知网格重建吃进新封面。
    @MainActor
    func cachedLibraryCoverMetadata(localFileURL: URL?) -> LibraryCoverMetadata? {
        let record = MediaLibraryService.shared.downloadRecord(for: id)
        return LibraryCoverMetadataStore.shared.cachedMetadata(
            itemID: id,
            localFileURL: localFileURL,
            bakedVideoPath: record?.sceneBakeArtifact?.videoPath
        )
    }

    /// 命中缓存时的封面 URL；未命中返回 nil（不要在这里触发解析）。
    @MainActor
    func cachedLibraryCoverURL(localFileURL: URL?) -> URL? {
        cachedLibraryCoverMetadata(localFileURL: localFileURL)?.thumbnailURL
    }
}
