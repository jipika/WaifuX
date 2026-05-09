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
        status == .pending || status == .downloading
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
        downloadService.removeTask(id: task.id)
        if let wallpaper = task.wallpaper {
            _ = downloadService.addTask(wallpaper: wallpaper)
        } else if let mediaItem = task.mediaItem {
            _ = downloadService.addTask(mediaItem: mediaItem)
        }
    }

    // MARK: - Computed Properties

    var activeTasks: [DownloadTask] {
        tasks.filter { $0.status == .pending || $0.status == .downloading || $0.status == .paused }
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

    private let downloadService: DownloadTaskService
    private var cancellables = Set<AnyCancellable>()

    init(downloadService: DownloadTaskService = .shared) {
        self.downloadService = downloadService

        downloadService.$tasks
            .receive(on: DispatchQueue.main)
            .map(Self.makePresentationState)
            .removeDuplicates(by: { lhs, rhs in
                lhs.activeCount == rhs.activeCount && lhs.snapshot == rhs.snapshot
            })
            .sink { [weak self] state in
                self?.snapshot = state.snapshot
                self?.activeTaskCount = state.activeCount
            }
            .store(in: &cancellables)
    }

    func isSuppressed(taskID: String) -> Bool {
        downloadService.isToastSuppressed(for: taskID)
    }

    func clearSuppression(taskID: String) {
        downloadService.clearToastSuppression(for: taskID)
    }

    private static func makePresentationState(from tasks: [DownloadTask]) -> (snapshot: DownloadToastSnapshot?, activeCount: Int) {
        let activeCount = tasks.filter(\.isRunning).count

        if let runningTask = tasks
            .filter(\.isRunning)
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
            return (DownloadToastSnapshot(task: runningTask), activeCount)
        }

        if let actionableTask = tasks
            .filter({ task in
                let referenceDate = task.completedAt ?? task.lastUpdatedAt
                let isActionable = task.status == .failed || task.status == .cancelled || task.status == .paused
                return isActionable && Date().timeIntervalSince(referenceDate) < 30
            })
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
            return (DownloadToastSnapshot(task: actionableTask), activeCount)
        }

        if let recentCompletedTask = tasks
            .filter({ task in
                guard task.status == .completed else { return false }
                let referenceDate = task.completedAt ?? task.lastUpdatedAt
                return Date().timeIntervalSince(referenceDate) < 1.8
            })
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
            return (DownloadToastSnapshot(task: recentCompletedTask), activeCount)
        }

        return (nil, activeCount)
    }
}
