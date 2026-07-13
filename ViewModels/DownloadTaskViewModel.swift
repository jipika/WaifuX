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
        id = task.id
        kind = task.kind
        title = task.title
        subtitle = task.subtitle
        badgeText = task.badgeText
        progress = task.progress
        status = task.status
        lastUpdatedAt = task.lastUpdatedAt
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
final class DownloadToastViewModel: ObservableObject {
    @Published private(set) var snapshot: DownloadToastSnapshot?
    @Published private(set) var activeTaskCount = 0
    @Published private(set) var steamCMDQueuedCount = 0

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

        downloadService.$tasks
            .receive(on: DispatchQueue.main)
            .map { [weak self] tasks -> (snapshot: DownloadToastSnapshot?, activeCount: Int) in
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
        let runningTasks = tasks.filter(\.isRunning)
        let visibleRunningTasks = runningTasks.filter { !downloadService.isToastSuppressed(for: $0.id) }
        let activeCount = visibleRunningTasks.count

        if let preferredID = preferredRunningTaskID,
           !runningTasks.contains(where: { $0.id == preferredID }) {
            preferredRunningTaskID = nil
        }

        if let preferredID = preferredRunningTaskID,
           let task = visibleRunningTasks.first(where: { $0.id == preferredID }) {
            return emit(coalescedRunningSnapshot(for: task), activeCount: activeCount)
        }

        if let runningTask = visibleRunningTasks.max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
            preferredRunningTaskID = runningTask.id
            return emit(coalescedRunningSnapshot(for: runningTask), activeCount: activeCount)
        }

        preferredRunningTaskID = nil

        if let actionableTask = tasks
            .filter({ task in
                let referenceDate = task.completedAt ?? task.lastUpdatedAt
                let isActionable = task.status == .failed || task.status == .cancelled || task.status == .paused
                return isActionable
                    && !downloadService.isToastSuppressed(for: task.id)
                    && Date().timeIntervalSince(referenceDate) < 30
            })
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
            return emit(DownloadToastSnapshot(task: actionableTask), activeCount: activeCount)
        }

        if let recentCompletedTask = tasks
            .filter({ task in
                guard task.status == .completed else { return false }
                let referenceDate = task.completedAt ?? task.lastUpdatedAt
                return !downloadService.isToastSuppressed(for: task.id)
                    && Date().timeIntervalSince(referenceDate) < 1.8
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
        let enoughProgressChanged = abs(nextSnapshot.progress - previous.progress) >= 0.02

        guard enoughTimePassed || enoughProgressChanged else {
            return previous
        }

        lastToastProgressEmitDate = now
        return nextSnapshot
    }
}
