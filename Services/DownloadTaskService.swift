import Foundation
import Combine

@MainActor
class DownloadTaskService: ObservableObject {
    static let shared = DownloadTaskService()

    @Published var tasks: [DownloadTask] = []
    /// 下载弹窗前后台切换不会改变任务本身，单独发布此版本号以刷新展示层。
    @Published private(set) var toastPresentationRevision = 0

    private let userDefaultsKey = "download_tasks"
    private var saveTask: Task<Void, Never>?
    private var lastProgressUpdateTimes: [String: Date] = [:]
    private let progressUpdateMinInterval: TimeInterval = 0.08
    private var suppressedToastTaskIDs = Set<String>()
    /// A retry can reuse the same user-facing task id. The token keeps late
    /// cancellation/unregistration from an older transfer away from the retry.
    private var downloadRegistrationTokens: [String: UUID] = [:]

    private struct ActiveDownload {
        let token: UUID
        let cancel: @Sendable () -> Void
    }

    /// `DownloadTaskService` is main-actor isolated, so keeping the actual
    /// transfer handles here preserves strict registration/cancellation order.
    /// Crossing to a second actor made a late old registration capable of
    /// displacing a newer retry for the same user-facing task id.
    private var activeDownloads: [String: ActiveDownload] = [:]

    // MARK: - Active Download Tasks Management
    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
        // 任务列表通过 restoreSavedTasks() 延迟恢复
    }

    /// 延迟恢复保存的下载任务（必须在 applicationDidFinishLaunching 中调用）
    func restoreSavedTasks() {
        loadTasks()
    }

    // MARK: - Task Management

    func addTask(wallpaper: Wallpaper, suppressToast: Bool = false) -> DownloadTask {
        enqueueTask(DownloadTask(wallpaper: wallpaper), suppressToast: suppressToast)
    }

    func addTask(mediaItem: MediaItem, suppressToast: Bool = false) -> DownloadTask {
        enqueueTask(DownloadTask(mediaItem: mediaItem), suppressToast: suppressToast)
    }

    func addTask(workshopWallpaper: MediaItem, suppressToast: Bool = false) -> DownloadTask {
        enqueueTask(DownloadTask(workshopWallpaper: workshopWallpaper), suppressToast: suppressToast)
    }

    /// 用户新增前台下载时，将已有的紧凑后台条恢复为大下载框。
    /// 自动触发的下载显式传入 `suppressToast: true`，继续保持不打断浏览。
    private func enqueueTask(_ task: DownloadTask, suppressToast: Bool) -> DownloadTask {
        let existingTask = tasks.first { $0.id == task.id }
        let isNewTask = existingTask == nil
        let hasBackgroundDownload = tasks.contains {
            $0.isRunning && suppressedToastTaskIDs.contains($0.id)
        }
        if existingTask?.isRunning != true {
            downloadRegistrationTokens[task.id] = UUID()
        }
        configureToastSuppression(for: task.id, suppressToast: suppressToast)
        let queuedTask = upsertTask(task)

        if isNewTask, !suppressToast, hasBackgroundDownload {
            restoreAllRunningToasts()
        }
        return queuedTask
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

    func cancelTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        // 取消正在进行的下载任务
        let token = registrationToken(for: id)
        cancelRegisteredDownload(id: id, token: token)

        objectWillChange.send()
        tasks[index].status = .cancelled
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        lastProgressUpdateTimes.removeValue(forKey: id)
        persistTasks()

        print("[DownloadTaskService] Task \(id) cancelled")
    }

    // MARK: - Active Download Management

    /// 注册一个活动的下载任务
    @discardableResult
    func registerDownloadTask<Success>(id: String, task: Task<Success, Error>) -> UUID {
        let token = registrationToken(for: id)
        if let previous = activeDownloads[id], previous.token != token {
            previous.cancel()
        }
        activeDownloads[id] = ActiveDownload(token: token, cancel: { task.cancel() })
        return token
    }

    /// 注销一个活动的下载任务
    func unregisterDownloadTask(id: String, token: UUID) {
        if activeDownloads[id]?.token == token {
            activeDownloads[id] = nil
        }
    }

    func removeTask(id: String) {
        let shouldCancelTransfer = tasks.first(where: { $0.id == id })?.isRunning == true
        let token = downloadRegistrationTokens[id]
        if shouldCancelTransfer, let token {
            cancelRegisteredDownload(id: id, token: token)
        }
        objectWillChange.send()
        tasks.removeAll { $0.id == id }
        lastProgressUpdateTimes.removeValue(forKey: id)
        suppressedToastTaskIDs.remove(id)
        downloadRegistrationTokens[id] = nil
        persistTasks()
    }

    private func registrationToken(for id: String) -> UUID {
        if let token = downloadRegistrationTokens[id] {
            return token
        }
        let token = UUID()
        downloadRegistrationTokens[id] = token
        return token
    }

    private func cancelRegisteredDownload(id: String, token: UUID) {
        guard let activeDownload = activeDownloads[id], activeDownload.token == token else {
            return
        }
        activeDownloads[id] = nil
        activeDownload.cancel()
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

    /// 批量抑制所有正在运行的下载任务的弹窗（“后台下载”按钮使用）。
    func suppressAllRunningToasts() {
        var changed = false
        for task in tasks where task.isRunning {
            changed = suppressedToastTaskIDs.insert(task.id).inserted || changed
        }
        if changed { publishToastPresentationChange() }
    }

    /// 将后台紧凑进度条恢复为完整下载弹窗。
    func restoreAllRunningToasts() {
        var changed = false
        for task in tasks where task.isRunning {
            changed = suppressedToastTaskIDs.remove(task.id) != nil || changed
        }
        if changed { publishToastPresentationChange() }
    }

    func clearToastSuppression(for id: String) {
        guard suppressedToastTaskIDs.remove(id) != nil else { return }
        publishToastPresentationChange()
    }

    func isToastSuppressed(for id: String) -> Bool {
        suppressedToastTaskIDs.contains(id)
    }

    func updateProgress(id: String, progress: Double) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !tasks[index].isTerminal else { return }
        let clampedProgress = min(max(progress, 0.0), 1.0)

        // 防抖优化：如果进度变化小于 0.5% 且不是开始/结束，跳过更新
        let currentProgress = tasks[index].progress
        let isStart = currentProgress == 0 && clampedProgress > 0
        let isComplete = clampedProgress >= 1.0
        if abs(clampedProgress - currentProgress) < 0.005 && !isStart && !isComplete {
            return
        }

        // 节流优化：限制高频进度发布，减少主线程重绘压力（约 12.5fps）
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
        guard !tasks[index].isTerminal else { return }
        objectWillChange.send()
        tasks[index].status = .completed
        tasks[index].progress = 1.0
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        lastProgressUpdateTimes.removeValue(forKey: id)
        persistTasks()
        scheduleVisibilityRefresh()
    }

    func markDownloading(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !tasks[index].isTerminal else { return }
        objectWillChange.send()
        tasks[index].status = .downloading
        tasks[index].lastUpdatedAt = .now
        persistTasks()
    }

    func markFailed(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !tasks[index].isTerminal else { return }
        objectWillChange.send()
        tasks[index].status = .failed
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        lastProgressUpdateTimes.removeValue(forKey: id)
        persistTasks()
    }

    private func configureToastSuppression(for id: String, suppressToast: Bool) {
        if suppressToast {
            if suppressedToastTaskIDs.insert(id).inserted {
                publishToastPresentationChange()
            }
        } else {
            if suppressedToastTaskIDs.remove(id) != nil {
                publishToastPresentationChange()
            }
        }
    }

    private func publishToastPresentationChange() {
        toastPresentationRevision &+= 1
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
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
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
        tasks.filter { $0.status == .downloading || $0.status == .pending || $0.status == .paused }
    }

    var runningTasks: [DownloadTask] {
        tasks
            .filter(\.isRunning)
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    /// The compact overlay represents one stable video task. Concurrent tasks
    /// retain their own progress in the status menu instead of replacing this bar
    /// whenever they happen to emit a newer progress update.
    var compactOverlayTask: DownloadTask? {
        let suppressedTasks = tasks.filter {
            $0.isRunning && suppressedToastTaskIDs.contains($0.id)
        }

        func firstTask(
            matching kinds: Set<DownloadTaskKind>,
            with status: DownloadStatus
        ) -> DownloadTask? {
            suppressedTasks
                .filter { kinds.contains($0.kind) && $0.status == status }
                .sorted(by: compactOverlayOrder)
                .first
        }

        let videoKinds: Set<DownloadTaskKind> = [.media, .workshop]
        return firstTask(matching: videoKinds, with: .downloading)
            ?? firstTask(matching: videoKinds, with: .pending)
            ?? firstTask(matching: Set(DownloadTaskKind.allCases), with: .downloading)
            ?? firstTask(matching: Set(DownloadTaskKind.allCases), with: .pending)
    }

    private func compactOverlayOrder(_ lhs: DownloadTask, _ rhs: DownloadTask) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    var libraryVisibleTasks: [DownloadTask] {
        tasks
            .filter(\.shouldAppearInLibrary)
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

}
