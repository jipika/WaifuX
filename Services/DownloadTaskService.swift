import Foundation
import Combine

// MARK: - Actor 隔离的下载任务存储
private actor DownloadTaskStorage {
    var activeDownloads: [String: Task<Void, Error>] = [:]
    var cancellationFlags: [String: Bool] = [:]

    func register(id: String, task: Task<Void, Error>) {
        activeDownloads[id] = task
        cancellationFlags[id] = false
    }

    func unregister(id: String) {
        activeDownloads.removeValue(forKey: id)
        cancellationFlags.removeValue(forKey: id)
    }

    func cancel(id: String) {
        activeDownloads[id]?.cancel()
        activeDownloads.removeValue(forKey: id)
        cancellationFlags[id] = true
    }

    func cancelAll() {
        for (_, task) in activeDownloads {
            task.cancel()
        }
        for id in activeDownloads.keys {
            cancellationFlags[id] = true
        }
        activeDownloads.removeAll()
    }

    func isCancelled(id: String) -> Bool {
        cancellationFlags[id] ?? false
    }

    func resetCancellationFlag(id: String) {
        cancellationFlags[id] = false
    }
}

@MainActor
class DownloadTaskService: ObservableObject {
    static let shared = DownloadTaskService()

    @Published var tasks: [DownloadTask] = []
    /// Presentation-only revision used when toast suppression changes without a
    /// transfer-state mutation.
    @Published private(set) var toastPresentationRevision = 0

    private let userDefaultsKey = "download_tasks"
    private var saveTask: Task<Void, Never>?
    private var lastProgressUpdateTimes: [String: Date] = [:]
    private let progressUpdateMinInterval: TimeInterval = 0.15
    private var suppressedToastTaskIDs = Set<String>()

    // MARK: - Active Download Tasks Management
    /// 使用 actor 隔离存储确保线程安全
    private let taskStorage = DownloadTaskStorage()

    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
        // 任务列表通过 restoreSavedTasks() 延迟恢复
    }

    /// 延迟恢复保存的下载任务（必须在 applicationDidFinishLaunching 中调用）
    func restoreSavedTasks() {
        loadTasks()
    }

    // MARK: - Task Management

    func addTask(wallpaper: Wallpaper) -> DownloadTask {
        upsertTask(DownloadTask(wallpaper: wallpaper))
    }

    func addTask(mediaItem: MediaItem) -> DownloadTask {
        upsertTask(DownloadTask(mediaItem: mediaItem))
    }

    func addTask(workshopWallpaper: MediaItem) -> DownloadTask {
        upsertTask(DownloadTask(workshopWallpaper: workshopWallpaper))
    }

    func updateWallpaper(_ wallpaper: Wallpaper, id: String? = nil) {
        let targetID = id ?? "wallpaper.\(wallpaper.id)"
        guard let index = tasks.firstIndex(where: { $0.id == targetID }) else { return }
        objectWillChange.send()
        tasks[index].wallpaper = wallpaper
        tasks[index].lastUpdatedAt = .now
        persistTasks()
    }

    func updateMediaItem(_ item: MediaItem, id: String? = nil) {
        let targetID = id ?? "media.\(item.id)"
        guard let index = tasks.firstIndex(where: { $0.id == targetID }) else { return }
        objectWillChange.send()
        tasks[index].mediaItem = item
        tasks[index].lastUpdatedAt = .now
        persistTasks()
    }

    private func upsertTask(_ task: DownloadTask) -> DownloadTask {
        objectWillChange.send()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
        persistTasks()
        return task
    }

    func pauseTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        PersistentDownloadQueueService.shared.pause(jobID: id)

        // 取消正在进行的下载任务（但保留进度）
        Task {
            await taskStorage.cancel(id: id)
        }

        objectWillChange.send()
        tasks[index].status = .paused
        tasks[index].lastUpdatedAt = .now
        persistTasks()

        print("[DownloadTaskService] Task \(id) paused")
    }

    func resumeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .paused
                || tasks[index].status == .failed
                || tasks[index].status == .waitingForSteamLogin else { return }

        objectWillChange.send()
        tasks[index].status = .pending
        tasks[index].completedAt = nil
        tasks[index].lastUpdatedAt = .now
        persistTasks()

        PersistentDownloadQueueService.shared.resume(jobID: id)
        print("[DownloadTaskService] Task \(id) resumed")
    }

    func cancelTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        PersistentDownloadQueueService.shared.cancel(jobID: id)

        // 取消正在进行的下载任务
        Task {
            await taskStorage.cancel(id: id)
        }

        objectWillChange.send()
        tasks[index].status = .cancelled
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        lastProgressUpdateTimes.removeValue(forKey: id)
        let removedSuppression = suppressedToastTaskIDs.remove(id) != nil
        persistTasks()
        if removedSuppression { publishToastPresentationChange() }

        print("[DownloadTaskService] Task \(id) cancelled")
    }

    // MARK: - Active Download Management

    /// 注册一个活动的下载任务
    func registerDownloadTask(id: String, task: Task<Void, Error>) {
        Task {
            await taskStorage.register(id: id, task: task)
        }
    }

    /// 注销一个活动的下载任务
    func unregisterDownloadTask(id: String) {
        Task {
            await taskStorage.unregister(id: id)
        }
    }

    /// 检查下载是否被取消（异步版本，避免主线程信号量死锁）
    func isDownloadCancelled(id: String) async -> Bool {
        await taskStorage.isCancelled(id: id)
    }

    /// 检查下载是否被取消（同步版本，仅用于非主线程场景）
    /// ⚠️ 不要在 @MainActor 上下文中调用此方法，会导致死锁
    nonisolated func isDownloadCancelledSync(id: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Bool>(value: false)
        Task { [box] in
            let result = await self.taskStorage.isCancelled(id: id)
            box.value = result
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    /// 用于跨并发域传递可变状态的盒子
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T
        init(value: T) {
            self.value = value
        }
    }

    /// 取消所有活动的下载
    func cancelAllActiveDownloads() {
        let activeTaskIDs = tasks
            .filter(\.isRunning)
            .map(\.id)
        for id in activeTaskIDs {
            cancelTask(id: id)
        }
    }

    func removeTask(id: String) {
        objectWillChange.send()
        tasks.removeAll { $0.id == id }
        lastProgressUpdateTimes.removeValue(forKey: id)
        suppressedToastTaskIDs.remove(id)
        persistTasks()
    }

    func task(for id: String) -> DownloadTask? {
        tasks.first { $0.id == id }
    }

    func task(for itemID: String, kind: DownloadTaskKind) -> DownloadTask? {
        tasks.first { $0.kind == kind && $0.itemID == itemID }
    }

    func markToastSuppressed(for id: String) {
        guard suppressedToastTaskIDs.insert(id).inserted else { return }
        publishToastPresentationChange()
    }

    /// 批量抑制所有正在运行的下载任务的 toast（"后台继续"按钮使用）
    func suppressAllRunningToasts() {
        var changed = false
        for task in tasks where task.isRunning {
            changed = suppressedToastTaskIDs.insert(task.id).inserted || changed
        }
        if changed { publishToastPresentationChange() }
    }

    func clearToastSuppression(for id: String) {
        guard suppressedToastTaskIDs.remove(id) != nil else { return }
        publishToastPresentationChange()
    }

    func restoreAllRunningToasts() {
        let runningIDs = Set(tasks.filter(\.isRunning).map(\.id))
        guard !runningIDs.isEmpty else { return }
        let before = suppressedToastTaskIDs.count
        suppressedToastTaskIDs.subtract(runningIDs)
        if suppressedToastTaskIDs.count != before {
            publishToastPresentationChange()
        }
    }

    func isToastSuppressed(for id: String) -> Bool {
        suppressedToastTaskIDs.contains(id)
    }

    private func publishToastPresentationChange() {
        toastPresentationRevision &+= 1
    }

    func updateProgress(id: String, progress: Double) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let currentProgress = tasks[index].progress
        // 一个 Job 内的多阶段回调可能延迟到达，UI 进度只能单调递增。
        let clampedProgress = max(currentProgress, min(max(progress, 0.0), 1.0))

        // 防抖优化：如果进度变化小于 0.5% 且不是开始/结束，跳过更新
        let isStart = currentProgress == 0 && clampedProgress > 0
        let isComplete = clampedProgress >= 1.0
        if abs(clampedProgress - currentProgress) < 0.005 && !isStart && !isComplete {
            return
        }

        // 节流优化：限制高频进度发布，减少主线程重绘压力（约 6.7fps）
        let now = Date()
        if !isStart && !isComplete,
           let lastTime = lastProgressUpdateTimes[id],
           now.timeIntervalSince(lastTime) < progressUpdateMinInterval {
            return
        }

        objectWillChange.send()
        tasks[index].progress = clampedProgress
        if tasks[index].status != .paused {
            tasks[index].status = .downloading
        }
        tasks[index].lastUpdatedAt = .now
        lastProgressUpdateTimes[id] = now
        schedulePersistTasks()
    }

    func markCompleted(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].status = .completed
        tasks[index].progress = 1.0
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        lastProgressUpdateTimes.removeValue(forKey: id)
        let removedSuppression = suppressedToastTaskIDs.remove(id) != nil
        persistTasks()
        if removedSuppression { publishToastPresentationChange() }
        scheduleVisibilityRefresh()
    }

    func markDownloading(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].status = .downloading
        tasks[index].lastUpdatedAt = .now
        persistTasks()
    }

    func markPending(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].status = .pending
        tasks[index].completedAt = nil
        tasks[index].lastUpdatedAt = .now
        persistTasks()
    }

    func markWaitingForSteamLogin(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].status = .waitingForSteamLogin
        tasks[index].completedAt = nil
        tasks[index].lastUpdatedAt = .now
        lastProgressUpdateTimes.removeValue(forKey: id)
        persistTasks()
    }

    func markPaused(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].status = .paused
        tasks[index].lastUpdatedAt = .now
        persistTasks()
    }

    func markFailed(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].status = .failed
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        lastProgressUpdateTimes.removeValue(forKey: id)
        let removedSuppression = suppressedToastTaskIDs.remove(id) != nil
        persistTasks()
        if removedSuppression { publishToastPresentationChange() }
    }

    // MARK: - Persistence

    /// 后台持久化队列，避免 JSON 编码 + UserDefaults 写入阻塞主线程
    private static let persistQueue = DispatchQueue(label: "com.waifux.downloadTask.persist", qos: .utility)

    private func persistTasks() {
        saveTask?.cancel()
        // ⚡ 在主线程捕获数据副本，后台编码写入
        let currentTasks = tasks
        let key = userDefaultsKey
        Self.persistQueue.async {
            if let encoded = try? JSONEncoder().encode(currentTasks) {
                UserDefaults.standard.set(encoded, forKey: key)
            }
        }
    }

    private func schedulePersistTasks() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { return }
            persistTasks()
        }
    }

    private func scheduleVisibilityRefresh() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_900_000_000) // 1.9s
            objectWillChange.send()
        }
    }

    private func loadTasks() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let loadedTasks = try? JSONDecoder().decode([DownloadTask].self, from: data) {
            // 重置中间态任务为暂停状态（因为重启后下载不会自动继续）
            tasks = loadedTasks.map { task in
                var modifiedTask = task
                if task.status == .downloading || task.status == .pending {
                    modifiedTask.status = .paused
                    modifiedTask.lastUpdatedAt = .now
                }
                return modifiedTask
            }
        }
    }

    // MARK: - Statistics

    var activeTasks: [DownloadTask] {
        tasks.filter {
            $0.status == .downloading
                || $0.status == .pending
                || $0.status == .waitingForSteamLogin
                || $0.status == .paused
        }
    }

    var runningTasks: [DownloadTask] {
        tasks
            .filter(\.isRunning)
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    var libraryVisibleTasks: [DownloadTask] {
        tasks
            .filter(\.shouldAppearInLibrary)
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    var latestOverlayTask: DownloadTask? {
        if let runningTask = runningTasks.first {
            return runningTask
        }

        return tasks
            .filter { $0.status == .completed }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .first(where: { Date().timeIntervalSince($0.lastUpdatedAt) < 1.8 })
    }

    var compactOverlayTask: DownloadTask? {
        tasks
            .filter { $0.isRunning && suppressedToastTaskIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
            .first
    }

    var completedTasks: [DownloadTask] {
        tasks.filter { $0.status == .completed }
    }

    var failedTasks: [DownloadTask] {
        tasks.filter { $0.status == .failed }
    }

    var latestTask: DownloadTask? {
        tasks.max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt })
    }
}

// MARK: - 统一可恢复下载执行队列

/// 所有下载入口共用的可执行事实源。`DownloadTaskService` 仅保留 UI 快照和历史；
/// 是否能在重启后恢复、当前是否占用下载槽位，一律以这里的 Job 为准。
@MainActor
final class PersistentDownloadQueueService {
    static let shared = PersistentDownloadQueueService()

    private enum Payload: Codable {
        case wallpaper(Wallpaper)
        case media(MediaItem, MediaDownloadOption?, saveToLibrary: Bool)
        case workshop(MediaItem)

        var taskID: String {
            switch self {
            case .wallpaper(let wallpaper):
                return "wallpaper.\(wallpaper.id)"
            case .media(let item, _, _):
                return "media.\(item.id)"
            case .workshop(let item):
                return "workshop.\(item.id)"
            }
        }

        var itemID: String {
            switch self {
            case .wallpaper(let wallpaper): return wallpaper.id
            case .media(let item, _, _), .workshop(let item): return item.id
            }
        }

        @MainActor
        var isAlreadyDownloaded: Bool {
            switch self {
            case .wallpaper(let wallpaper):
                return WallpaperLibraryService.shared.isDownloaded(wallpaper)
            case .media(let item, _, _), .workshop(let item):
                return MediaLibraryService.shared.isDownloaded(item)
            }
        }
    }

    private enum State: String, Codable {
        case queued
        case running
        case waitingForSteamLogin
        case paused
        case failed
    }

    private enum Source: String, Codable {
        case manual
        case folderRedownload
        case legacyMigration
    }

    private struct Job: Codable, Identifiable {
        let id: String
        var payload: Payload
        var folderID: String?
        var state: State
        var source: Source
        let addedAt: Date
        var updatedAt: Date
        var attemptCount: Int
        var lastError: String?
    }

    private struct Snapshot: Codable {
        let version: Int
        let jobs: [Job]
    }

    private struct ActiveWorker {
        let token: UUID
        let task: Task<Void, Error>
    }

    /// 兼容上一版仅服务于“文件夹重新下载”的 UserDefaults Job。
    private struct LegacyMediaJob: Codable {
        let id: String
        let item: MediaItem
        let folderID: String
        let addedAt: Date
    }

    private enum QueueError: LocalizedError {
        case notConfigured
        case missingResult
        case persistenceFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "下载队列尚未完成启动配置"
            case .missingResult: return "下载完成但没有返回本地文件"
            case .persistenceFailed: return "无法将下载队列保存到本地"
            }
        }
    }

    private let maxConcurrentDownloads = 2
    private let legacyDefaultsKey = "persistent_media_download_queue_v1"
    private var jobs: [Job] = []
    private var activeWorkers: [String: ActiveWorker] = [:]
    private var completionWaiters: [String: [CheckedContinuation<URL?, Error>]] = [:]
    /// 覆盖“共享 Job 刚结束，新调用方尚未来得及挂起”的竞态窗口。
    private var terminalResults: [String: Result<URL?, Error>] = [:]
    private var terminalResultOrder: [String] = []
    private var didRestore = false
    private var shouldResumeWaitingJobsAfterRestore = false
    private weak var wallpaperViewModel: WallpaperViewModel?
    private weak var mediaViewModel: MediaExploreViewModel?

    private init() {}

    /// 应用启动时注入长期存活的执行器，并恢复所有未完成 Job。
    func configure(
        wallpaperViewModel: WallpaperViewModel,
        mediaViewModel: MediaExploreViewModel
    ) {
        self.wallpaperViewModel = wallpaperViewModel
        self.mediaViewModel = mediaViewModel

        guard !didRestore else {
            pump()
            return
        }
        didRestore = true
        restoreAndMigrateJobs()
        if shouldResumeWaitingJobsAfterRestore {
            shouldResumeWaitingJobsAfterRestore = false
            resumeWaitingForSteamLogin()
        } else {
            pump()
        }
    }

    func enqueueWallpaperAndWait(
        _ wallpaper: Wallpaper,
        folderID: String?,
        using viewModel: WallpaperViewModel
    ) async throws {
        wallpaperViewModel = viewModel
        let id = try upsert(
            payload: .wallpaper(wallpaper),
            folderID: folderID,
            source: .manual,
            persistImmediately: true
        )
        _ = try await waitForCompletion(of: id)
    }

    func enqueueMediaAndWait(
        _ item: MediaItem,
        option: MediaDownloadOption?,
        saveToLibrary: Bool,
        folderID: String?,
        using viewModel: MediaExploreViewModel
    ) async throws -> URL {
        mediaViewModel = viewModel
        let payload: Payload = item.id.hasPrefix("workshop_")
            ? .workshop(item)
            : .media(item, option, saveToLibrary: saveToLibrary)
        let id = try upsert(
            payload: payload,
            folderID: folderID,
            source: .manual,
            persistImmediately: true
        )
        guard let result = try await waitForCompletion(of: id) else {
            throw QueueError.missingResult
        }
        return result
    }

    func enqueueWorkshopAndWait(
        _ item: MediaItem,
        folderID: String?,
        using viewModel: MediaExploreViewModel
    ) async throws {
        mediaViewModel = viewModel
        let id = try upsert(
            payload: .workshop(item),
            folderID: folderID,
            source: .manual,
            persistImmediately: true
        )
        _ = try await waitForCompletion(of: id)
    }

    /// 重新下载必须先完整落盘 Job，再允许调用方删除旧文件。
    /// `folderID` 为 nil 或空时，下载完成后回到库根目录。
    @discardableResult
    func stage(_ items: [MediaItem], folderID: String?) -> Bool {
        guard !items.isEmpty else { return false }
        let originalJobs = jobs
        var presentationPayloads: [Payload] = []
        let normalizedFolderID = folderID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFolderID = (normalizedFolderID?.isEmpty == false) ? normalizedFolderID : nil
        for item in items {
            let payload: Payload = item.id.hasPrefix("workshop_")
                ? .workshop(item)
                : .media(item, nil, saveToLibrary: true)
            if let existing = jobs.first(where: { $0.id == payload.taskID }) {
                if existing.state == .failed || existing.state == .paused {
                    presentationPayloads.append(payload)
                }
            } else {
                presentationPayloads.append(payload)
            }
            do {
                _ = try upsert(
                    payload: payload,
                    folderID: resolvedFolderID,
                    source: .folderRedownload,
                    persistImmediately: false,
                    updatePresentation: false
                )
            } catch {
                jobs = originalJobs
                return false
            }
        }
        guard persistJobs() else {
            jobs = originalJobs
            return false
        }
        for payload in presentationPayloads {
            addPresentationTask(for: payload)
            DownloadTaskService.shared.markPending(id: payload.taskID)
        }
        return true
    }

    /// 兼容旧调用；新调度器始终滚动补齐两个槽位，不再按固定批次等待。
    func start(using viewModel: MediaExploreViewModel) {
        mediaViewModel = viewModel
        pump()
    }

    func pause(jobID: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = .paused
        jobs[index].updatedAt = .now
        activeWorkers[jobID]?.task.cancel()
        persistJobs()
    }

    func resume(jobID: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .paused
                || jobs[index].state == .failed
                || jobs[index].state == .waitingForSteamLogin else {
            return
        }
        jobs[index].state = .queued
        jobs[index].updatedAt = .now
        jobs[index].lastError = nil
        clearTerminalResult(for: jobID)
        DownloadTaskService.shared.markPending(id: jobID)
        persistJobs()
        pump()
    }

    func resumeWaitingForSteamLogin() {
        guard didRestore else {
            shouldResumeWaitingJobsAfterRestore = true
            return
        }
        var resumedJobIDs: [String] = []
        for index in jobs.indices where jobs[index].state == .waitingForSteamLogin {
            jobs[index].state = .queued
            jobs[index].updatedAt = .now
            jobs[index].lastError = nil
            clearTerminalResult(for: jobs[index].id)
            resumedJobIDs.append(jobs[index].id)
        }
        guard !resumedJobIDs.isEmpty else {
            pump()
            return
        }
        for jobID in resumedJobIDs {
            DownloadTaskService.shared.markPending(id: jobID)
        }
        persistJobs()
        pump()
    }

    func cancel(jobID: String) {
        activeWorkers[jobID]?.task.cancel()
        activeWorkers.removeValue(forKey: jobID)
        jobs.removeAll { $0.id == jobID }
        let result: Result<URL?, Error> = .failure(CancellationError())
        storeTerminalResult(result, for: jobID)
        resumeWaiters(for: jobID, with: result)
        persistJobs()
        pump()
    }

    func retry(_ task: DownloadTask) {
        if jobs.contains(where: { $0.id == task.id }) {
            resume(jobID: task.id)
            return
        }

        let payload: Payload?
        switch task.kind {
        case .wallpaper:
            payload = task.wallpaper.map(Payload.wallpaper)
        case .media:
            payload = task.mediaItem.map { .media($0, nil, saveToLibrary: true) }
        case .workshop:
            payload = (task.workshopItem ?? task.mediaItem).map(Payload.workshop)
        }
        guard let payload else { return }
        do {
            _ = try upsert(
                payload: payload,
                folderID: nil,
                source: .manual,
                persistImmediately: true
            )
        } catch {
            DownloadTaskService.shared.markFailed(id: task.id)
            return
        }
        pump()
    }

    func retryAndWait(_ task: DownloadTask) async throws {
        retry(task)
        guard jobs.contains(where: { $0.id == task.id }) else {
            throw QueueError.missingResult
        }
        _ = try await waitForCompletion(of: task.id)
    }

    private func waitForCompletion(of jobID: String) async throws -> URL? {
        if let result = terminalResults[jobID] {
            return try result.get()
        }
        guard jobs.contains(where: { $0.id == jobID }) else {
            throw QueueError.missingResult
        }
        return try await withCheckedThrowingContinuation { continuation in
            completionWaiters[jobID, default: []].append(continuation)
            pump()
        }
    }

    @discardableResult
    private func upsert(
        payload: Payload,
        folderID: String?,
        source: Source,
        persistImmediately: Bool,
        updatePresentation: Bool = true
    ) throws -> String {
        let originalJobs = jobs
        let id = payload.taskID
        let normalizedFolderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var shouldResetPresentation = false
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            // 已运行的 worker 持有当时的 Job 快照，不在中途改写路径/参数。
            if jobs[index].state != .running {
                jobs[index].payload = payload
                jobs[index].folderID = normalizedFolderID?.isEmpty == false ? normalizedFolderID : nil
                jobs[index].source = source
            }
            if jobs[index].state == .failed || jobs[index].state == .paused {
                jobs[index].state = .queued
                jobs[index].lastError = nil
                shouldResetPresentation = true
            }
            jobs[index].updatedAt = .now
        } else {
            jobs.append(
                Job(
                    id: id,
                    payload: payload,
                    folderID: normalizedFolderID?.isEmpty == false ? normalizedFolderID : nil,
                    state: .queued,
                    source: source,
                    addedAt: .now,
                    updatedAt: .now,
                    attemptCount: 0,
                    lastError: nil
                )
            )
            shouldResetPresentation = true
        }
        jobs.sort { $0.addedAt < $1.addedAt }
        // 相同下载的多个调用方共享一个 Job；不覆盖正在进展的 UI 快照，
        // 否则进度会被重置为 0 并表现为数字乱跳。
        if persistImmediately && !persistJobs() {
            jobs = originalJobs
            throw QueueError.persistenceFailed
        }
        if shouldResetPresentation {
            clearTerminalResult(for: id)
        }
        if updatePresentation && shouldResetPresentation {
            addPresentationTask(for: payload)
            DownloadTaskService.shared.markPending(id: id)
        }
        return id
    }

    /// 动态 worker pool：任意槽位结束后立即取下一个 FIFO Job。
    private func pump() {
        while activeWorkers.count < maxConcurrentDownloads,
              let index = jobs.firstIndex(where: { $0.state == .queued }) {
            jobs[index].state = .running
            jobs[index].updatedAt = .now
            jobs[index].attemptCount += 1
            let job = jobs[index]
            DownloadTaskService.shared.markDownloading(id: job.id)
            persistJobs()

            let workerToken = UUID()
            let worker = Task<Void, Error> { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.execute(job)
                    try Task.checkCancellation()
                    self.finish(jobID: job.id, workerToken: workerToken, result: result)
                } catch {
                    self.fail(jobID: job.id, workerToken: workerToken, error: error)
                    throw error
                }
            }
            activeWorkers[job.id] = ActiveWorker(token: workerToken, task: worker)
            DownloadTaskService.shared.registerDownloadTask(id: job.id, task: worker)
        }
    }

    private func execute(_ job: Job) async throws -> URL? {
        switch job.payload {
        case .wallpaper(let wallpaper):
            guard let wallpaperViewModel else { throw QueueError.notConfigured }
            try await wallpaperViewModel.executeQueuedWallpaperDownload(
                wallpaper,
                folderID: job.folderID,
                taskID: job.id
            )
            return nil
        case .media(let item, let option, let saveToLibrary):
            guard let mediaViewModel else { throw QueueError.notConfigured }
            return try await mediaViewModel.executeQueuedMediaDownload(
                item,
                option: option,
                saveToLibrary: saveToLibrary,
                folderID: job.folderID,
                taskID: job.id
            )
        case .workshop(let item):
            guard let mediaViewModel else { throw QueueError.notConfigured }
            return try await mediaViewModel.executeQueuedWorkshopDownload(
                item,
                folderID: job.folderID,
                taskID: job.id
            )
        }
    }

    private func finish(jobID: String, workerToken: UUID, result: URL?) {
        guard activeWorkers[jobID]?.token == workerToken else { return }
        activeWorkers.removeValue(forKey: jobID)
        DownloadTaskService.shared.unregisterDownloadTask(id: jobID)

        // 先从执行队列移除并补上下一个 Job，再发布当前 Job 的完成状态。
        // 否则 Toast 会先收到“已完成”并启动自动隐藏计时，随后才收到下一个
        // Job 开始，批量下载时就会出现弹窗逐项消失又重新弹出的闪烁。
        jobs.removeAll { $0.id == jobID }
        persistJobs()
        let terminalResult: Result<URL?, Error> = .success(result)
        storeTerminalResult(terminalResult, for: jobID)
        resumeWaiters(for: jobID, with: terminalResult)
        pump()

        // 队列已补位后再标记完成；若没有下一个 Job，这里仍会正常进入
        // 完成态并由 Toast 按原逻辑短暂展示后消失。
        DownloadTaskService.shared.markCompleted(id: jobID)
    }

    private func fail(jobID: String, workerToken: UUID, error: Error) {
        // 取消后同 ID 可能已经重新入队；旧 worker 绝不能删掉新 Job/worker。
        guard activeWorkers[jobID]?.token == workerToken else { return }
        activeWorkers.removeValue(forKey: jobID)
        DownloadTaskService.shared.unregisterDownloadTask(id: jobID)

        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            let result: Result<URL?, Error> = .failure(error)
            storeTerminalResult(result, for: jobID)
            resumeWaiters(for: jobID, with: result)
            pump()
            return
        }

        if jobs[index].state == .paused {
            let result: Result<URL?, Error> = .failure(CancellationError())
            storeTerminalResult(result, for: jobID)
            resumeWaiters(for: jobID, with: result)
        } else if error is CancellationError {
            // 用户可能在旧 worker 退出前已点了“继续”。此时 Job 已回到
            // queued，必须保留并由 pump 立即重启，不能被旧 worker 删掉。
            if jobs[index].state != .queued {
                jobs.remove(at: index)
                let result: Result<URL?, Error> = .failure(error)
                storeTerminalResult(result, for: jobID)
                resumeWaiters(for: jobID, with: result)
            }
        } else if let workshopError = error as? WorkshopError,
                  workshopError.requiresSteamLoginRecovery,
                  case .workshop = jobs[index].payload {
            jobs[index].state = .waitingForSteamLogin
            jobs[index].updatedAt = .now
            jobs[index].lastError = error.localizedDescription
            DownloadTaskService.shared.markWaitingForSteamLogin(id: jobID)
            NotificationCenter.default.post(
                name: .steamWorkshopLoginRequired,
                object: jobs[index].payload.itemID,
                userInfo: ["message": error.localizedDescription]
            )
        } else {
            jobs[index].state = .failed
            jobs[index].updatedAt = .now
            jobs[index].lastError = error.localizedDescription
            DownloadTaskService.shared.markFailed(id: jobID)
            let result: Result<URL?, Error> = .failure(error)
            storeTerminalResult(result, for: jobID)
            resumeWaiters(for: jobID, with: result)
        }
        persistJobs()
        pump()
    }

    private func resumeWaiters(
        for jobID: String,
        with result: Result<URL?, Error>
    ) {
        let waiters = completionWaiters.removeValue(forKey: jobID) ?? []
        for waiter in waiters {
            switch result {
            case .success(let url): waiter.resume(returning: url)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private func storeTerminalResult(_ result: Result<URL?, Error>, for jobID: String) {
        terminalResults[jobID] = result
        terminalResultOrder.removeAll { $0 == jobID }
        terminalResultOrder.append(jobID)
        while terminalResultOrder.count > 100 {
            let expiredID = terminalResultOrder.removeFirst()
            terminalResults.removeValue(forKey: expiredID)
        }
    }

    private func clearTerminalResult(for jobID: String) {
        terminalResults.removeValue(forKey: jobID)
        terminalResultOrder.removeAll { $0 == jobID }
    }

    private func addPresentationTask(for payload: Payload) {
        switch payload {
        case .wallpaper(let wallpaper):
            _ = DownloadTaskService.shared.addTask(wallpaper: wallpaper)
        case .media(let item, _, _):
            _ = DownloadTaskService.shared.addTask(mediaItem: item)
        case .workshop(let item):
            _ = DownloadTaskService.shared.addTask(workshopWallpaper: item)
        }
    }

    private func restoreAndMigrateJobs() {
        jobs = loadSnapshotJobs()
        mergeLegacyMediaJobs()
        mergeLegacyPresentationTasks()

        var seen = Set<String>()
        jobs = jobs
            .sorted { $0.addedAt < $1.addedAt }
            .filter { seen.insert($0.id).inserted && !$0.payload.isAlreadyDownloaded }
            .map { job in
                var restored = job
                if restored.state == .running {
                    restored.state = .queued
                    restored.updatedAt = .now
                }
                return restored
            }

        for job in jobs {
            addPresentationTask(for: job.payload)
            switch job.state {
            case .queued, .running:
                DownloadTaskService.shared.markPending(id: job.id)
            case .waitingForSteamLogin:
                DownloadTaskService.shared.markWaitingForSteamLogin(id: job.id)
            case .paused:
                DownloadTaskService.shared.markPaused(id: job.id)
            case .failed:
                DownloadTaskService.shared.markFailed(id: job.id)
            }
        }
        if persistJobs() {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
    }

    private func loadSnapshotJobs() -> [Job] {
        guard let data = try? Data(contentsOf: checkpointURL) else { return [] }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data).jobs
        } catch {
            AppLogger.error(.download, "下载队列快照解码失败", metadata: [
                "path": checkpointURL.path,
                "error": error.localizedDescription
            ])
            return []
        }
    }

    private func mergeLegacyMediaJobs() {
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let legacyJobs = try? JSONDecoder().decode([LegacyMediaJob].self, from: data) else {
            return
        }
        for legacy in legacyJobs where !jobs.contains(where: { $0.id == legacy.id }) {
            let payload: Payload = legacy.item.id.hasPrefix("workshop_")
                ? .workshop(legacy.item)
                : .media(legacy.item, nil, saveToLibrary: true)
            jobs.append(
                Job(
                    id: payload.taskID,
                    payload: payload,
                    folderID: legacy.folderID,
                    state: .queued,
                    source: .legacyMigration,
                    addedAt: legacy.addedAt,
                    updatedAt: .now,
                    attemptCount: 0,
                    lastError: nil
                )
            )
        }
    }

    private func mergeLegacyPresentationTasks() {
        let unfinished = DownloadTaskService.shared.tasks.filter {
            $0.status == .pending
                || $0.status == .downloading
                || $0.status == .waitingForSteamLogin
                || $0.status == .paused
        }
        for task in unfinished where !jobs.contains(where: { $0.id == task.id }) {
            let payload: Payload?
            switch task.kind {
            case .wallpaper:
                payload = task.wallpaper.map(Payload.wallpaper)
            case .media:
                payload = task.mediaItem.map { .media($0, nil, saveToLibrary: true) }
            case .workshop:
                payload = (task.workshopItem ?? task.mediaItem).map(Payload.workshop)
            }
            guard let payload, !payload.isAlreadyDownloaded else { continue }
            let restoredState: State
            switch task.status {
            case .waitingForSteamLogin:
                restoredState = .waitingForSteamLogin
            case .paused:
                restoredState = .paused
            default:
                restoredState = .queued
            }
            jobs.append(
                Job(
                    id: payload.taskID,
                    payload: payload,
                    folderID: nil,
                    state: restoredState,
                    source: .legacyMigration,
                    addedAt: task.createdAt,
                    updatedAt: .now,
                    attemptCount: 0,
                    lastError: nil
                )
            )
        }
    }

    @discardableResult
    private func persistJobs() -> Bool {
        do {
            let directory = checkpointURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Snapshot(version: 2, jobs: jobs))
            try data.write(to: checkpointURL, options: .atomic)
            return true
        } catch {
            AppLogger.error(.download, "下载队列快照写入失败", metadata: [
                "path": checkpointURL.path,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    private var checkpointURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.waifux.app", isDirectory: true)
            .appendingPathComponent("DownloadQueue", isDirectory: true)
            .appendingPathComponent("download-queue-v2.json", isDirectory: false)
    }
}
