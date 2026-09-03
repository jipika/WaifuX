import Foundation
import Combine

struct DownloadToastSnapshot: Equatable, Identifiable {
    let id: String
    let kind: DownloadTaskKind
    let title: String
    let subtitle: String
    let badgeText: String
    let progress: Double
    let status: DownloadStatus
    let lastUpdatedAt: Date

    init(task: DownloadTask) {
        self.id = task.id
        self.kind = task.kind
        self.title = task.title
        self.subtitle = task.subtitle
        self.badgeText = task.badgeText
        self.progress = task.progress
        self.status = task.status
        self.lastUpdatedAt = task.lastUpdatedAt
    }

    var isRunning: Bool {
        status == .pending || status == .downloading || status == .waitingForSteamLogin
    }

    var isActionable: Bool {
        status == .failed || status == .cancelled || status == .paused
    }

    var isTerminal: Bool {
        status == .completed || status == .failed || status == .cancelled
    }
}

@MainActor
class DownloadTaskViewModel: ObservableObject {
    @Published var tasks: [DownloadTask] = []

    private let downloadService = DownloadTaskService.shared

    init() {
        // 仅桥接 tasks，避免重复 objectWillChange 转发导致全局重绘频率过高
        downloadService.$tasks
            .receive(on: DispatchQueue.main)
            .assign(to: &$tasks)
    }

    // MARK: - Task Actions

    func addTask(wallpaper: Wallpaper) {
        _ = downloadService.addTask(wallpaper: wallpaper)
    }

    func addTask(mediaItem: MediaItem) {
        _ = downloadService.addTask(mediaItem: mediaItem)
    }

    func pauseTask(_ task: DownloadTask) {
        downloadService.pauseTask(id: task.id)
    }

    func resumeTask(_ task: DownloadTask) {
        downloadService.resumeTask(id: task.id)
    }

    func cancelTask(_ task: DownloadTask) {
        downloadService.cancelTask(id: task.id)
    }

    func removeTask(_ task: DownloadTask) {
        downloadService.removeTask(id: task.id)
    }

    func retryTask(_ task: DownloadTask) {
        PersistentDownloadQueueService.shared.retry(task)
    }

    // MARK: - Computed Properties

    var activeTasks: [DownloadTask] {
        tasks.filter {
            $0.status == .pending
                || $0.status == .downloading
                || $0.status == .waitingForSteamLogin
                || $0.status == .paused
        }
    }

    var libraryVisibleTasks: [DownloadTask] {
        downloadService.libraryVisibleTasks
    }

    var wallpaperTasks: [DownloadTask] {
        libraryVisibleTasks.filter { $0.kind == .wallpaper }
    }

    var mediaTasks: [DownloadTask] {
        libraryVisibleTasks.filter { $0.kind == .media }
    }

    var completedTasks: [DownloadTask] {
        tasks.filter { $0.status == .completed }
    }

    var failedTasks: [DownloadTask] {
        tasks.filter { $0.status == .failed }
    }

    var hasActiveTasks: Bool {
        !activeTasks.isEmpty
    }

    var latestTask: DownloadTask? {
        downloadService.latestOverlayTask
    }
}

@MainActor
final class DownloadToastViewModel: ObservableObject {
    @Published private(set) var snapshot: DownloadToastSnapshot?
    @Published private(set) var activeTaskCount: Int = 0
    @Published private(set) var steamCMDQueuedCount: Int = 0

    private let downloadService: DownloadTaskService
    private let workshopService: WorkshopService
    private var cancellables = Set<AnyCancellable>()
    private var preferredRunningTaskID: String?
    private var lastEmittedSnapshot: DownloadToastSnapshot?
    private var lastToastProgressEmitDate: Date?
    private let runningProgressEmitInterval: TimeInterval = 0.20

    init(downloadService: DownloadTaskService = .shared, workshopService: WorkshopService = .shared) {
        self.downloadService = downloadService
        self.workshopService = workshopService

        Publishers.CombineLatest(
            downloadService.$tasks,
            downloadService.$toastPresentationRevision
        )
            .receive(on: DispatchQueue.main)
            .map { [weak self] values -> (snapshot: DownloadToastSnapshot?, activeCount: Int) in
                let (tasks, _) = values
                guard let self else { return (nil, 0) }
                return self.makePresentationState(from: tasks)
            }
            .removeDuplicates(by: { lhs, rhs in
                lhs.activeCount == rhs.activeCount && lhs.snapshot == rhs.snapshot
            })
            .sink { [weak self] state in
                self?.snapshot = state.snapshot
                self?.activeTaskCount = state.activeCount
            }
            .store(in: &cancellables)

        workshopService.$steamCMDQueuedCount
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .assign(to: &$steamCMDQueuedCount)
    }

    func isSuppressed(taskID: String) -> Bool {
        downloadService.isToastSuppressed(for: taskID)
    }

    func clearSuppression(taskID: String) {
        downloadService.clearToastSuppression(for: taskID)
    }

    private func makePresentationState(from tasks: [DownloadTask]) -> (snapshot: DownloadToastSnapshot?, activeCount: Int) {
        let activeCount = tasks.filter(\.isRunning).count
        let runningTasks = tasks.filter(\.isRunning)
        let visibleRunningTasks = runningTasks.filter { !downloadService.isToastSuppressed(for: $0.id) }

        // 如果被抑制的偏好任务重新可见了，清除偏好让它能被再次选中
        if let preferredID = preferredRunningTaskID,
           !runningTasks.contains(where: { $0.id == preferredID }) {
            preferredRunningTaskID = nil
        }

        // 固定显示当前偏好的 running 任务，避免多个任务同时下载时弹窗来回闪烁
        if let preferredID = preferredRunningTaskID,
           let task = visibleRunningTasks.first(where: { $0.id == preferredID }) {
            let snapshot = coalescedRunningSnapshot(for: task)
            return emit(snapshot, activeCount: activeCount)
        }

        // 选择最新的 running 任务并记住它
        if let runningTask = visibleRunningTasks.max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
            preferredRunningTaskID = runningTask.id
            let snapshot = coalescedRunningSnapshot(for: runningTask)
            return emit(snapshot, activeCount: activeCount)
        }

        preferredRunningTaskID = nil

        if let actionableTask = tasks
            .filter({ task in
                let referenceDate = task.completedAt ?? task.lastUpdatedAt
                let isActionable = task.status == .failed || task.status == .cancelled || task.status == .paused
                return isActionable && Date().timeIntervalSince(referenceDate) < 30
            })
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
            return emit(DownloadToastSnapshot(task: actionableTask), activeCount: activeCount)
        }

        if let recentCompletedTask = tasks
            .filter({ task in
                guard task.status == .completed else { return false }
                let referenceDate = task.completedAt ?? task.lastUpdatedAt
                return Date().timeIntervalSince(referenceDate) < 1.8
            })
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
            return emit(DownloadToastSnapshot(task: recentCompletedTask), activeCount: activeCount)
        }

        return emit(nil, activeCount: activeCount)
    }

    private func emit(_ snapshot: DownloadToastSnapshot?, activeCount: Int) -> (snapshot: DownloadToastSnapshot?, activeCount: Int) {
        lastEmittedSnapshot = snapshot
        if snapshot?.isRunning != true {
            lastToastProgressEmitDate = nil
        }
        return (snapshot, activeCount)
    }

    private func coalescedRunningSnapshot(for task: DownloadTask) -> DownloadToastSnapshot {
        let nextSnapshot = DownloadToastSnapshot(task: task)
        guard let previous = lastEmittedSnapshot,
              previous.id == nextSnapshot.id,
              previous.kind == nextSnapshot.kind,
              previous.title == nextSnapshot.title,
              previous.subtitle == nextSnapshot.subtitle,
              previous.badgeText == nextSnapshot.badgeText,
              previous.status == nextSnapshot.status,
              nextSnapshot.isRunning else {
            lastToastProgressEmitDate = Date()
            return nextSnapshot
        }

        let now = Date()
        let enoughTimePassed = lastToastProgressEmitDate.map {
            now.timeIntervalSince($0) >= runningProgressEmitInterval
        } ?? true
        // 0.02 → 0.05：高速下载时 2% 阈值几乎每帧命中，实际发布频率会突破节流上限；
        // 5% 变化对肉眼进度条几乎无差，但把最坏发布频率压回 ~6-7Hz
        let enoughProgressChanged = abs(nextSnapshot.progress - previous.progress) >= 0.05

        guard enoughTimePassed || enoughProgressChanged else {
            return previous
        }

        lastToastProgressEmitDate = now
        return nextSnapshot
    }
}
