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

    private let userDefaultsKey = "download_tasks"
    private var saveTask: Task<Void, Never>?

    // MARK: - Active Download Tasks Management
    /// 使用 actor 隔离存储确保线程安全
    private let taskStorage = DownloadTaskStorage()

    private init() {
        loadTasks()
    }

    // MARK: - Task Management

    func addTask(wallpaper: Wallpaper) -> DownloadTask {
        upsertTask(DownloadTask(wallpaper: wallpaper))
    }

    func addTask(mediaItem: MediaItem) -> DownloadTask {
        upsertTask(DownloadTask(mediaItem: mediaItem))
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
        guard tasks[index].status == .paused else { return }

        objectWillChange.send()
        tasks[index].status = .downloading
        tasks[index].lastUpdatedAt = .now
        persistTasks()

        // 注意：实际的下载恢复需要由调用方（如 WallpaperViewModel）重新启动下载
        // 这里只是更新状态，实际的下载逻辑在调用方处理
        print("[DownloadTaskService] Task \(id) marked for resume")
    }

    func cancelTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        // 取消正在进行的下载任务
        Task {
            await taskStorage.cancel(id: id)
        }

        objectWillChange.send()
        tasks[index].status = .cancelled
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        persistTasks()

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

    /// 检查下载是否被取消
    func isDownloadCancelled(id: String) -> Bool {
        // 使用同步方式获取，因为 actor 调用是异步的
        // 这里使用 Task 包装来同步等待结果
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        Task {
            result = await taskStorage.isCancelled(id: id)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// 取消所有活动的下载
    func cancelAllActiveDownloads() {
        Task {
            await taskStorage.cancelAll()
        }
    }

    func removeTask(id: String) {
        objectWillChange.send()
        tasks.removeAll { $0.id == id }
        persistTasks()
    }

    func task(for id: String) -> DownloadTask? {
        tasks.first { $0.id == id }
    }

    func task(for itemID: String, kind: DownloadTaskKind) -> DownloadTask? {
        tasks.first { $0.kind == kind && $0.itemID == itemID }
    }

    func updateProgress(id: String, progress: Double) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].progress = min(max(progress, 0.0), 1.0)
        if tasks[index].status != .paused {
            tasks[index].status = .downloading
        }
        tasks[index].lastUpdatedAt = .now
        schedulePersistTasks()
    }

    func markCompleted(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].status = .completed
        tasks[index].progress = 1.0
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        persistTasks()
        scheduleVisibilityRefresh()
    }

    func markFailed(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tasks[index].status = .failed
        tasks[index].completedAt = Date()
        tasks[index].lastUpdatedAt = .now
        persistTasks()
    }

    // MARK: - Persistence

    private func persistTasks() {
        saveTask?.cancel()
        if let encoded = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    private func schedulePersistTasks() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            guard !Task.isCancelled else { return }
            persistTasks()
        }
    }

    private func scheduleVisibilityRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000) // 1.9s
            objectWillChange.send()
        }
    }

    private func loadTasks() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let loadedTasks = try? JSONDecoder().decode([DownloadTask].self, from: data) {
            // 重置正在下载的任务为暂停状态（因为重启后下载应该暂停）
            tasks = loadedTasks.map { task in
                var modifiedTask = task
                if task.status == .downloading {
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
