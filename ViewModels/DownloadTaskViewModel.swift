import Foundation
import Combine

@MainActor
class DownloadTaskViewModel: ObservableObject {
    @Published var tasks: [DownloadTask] = []

    private let downloadService = DownloadTaskService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 监听下载服务的变化
        downloadService.$tasks
            .receive(on: DispatchQueue.main)
            .assign(to: &$tasks)

        downloadService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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
