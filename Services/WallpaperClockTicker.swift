import AppKit
import Combine

/// One clock wakeup for every desktop overlay and foreground clock preview.
@MainActor
final class WallpaperClockTicker {
    static let shared = WallpaperClockTicker()
    @Published private(set) var now = Date()
    private var consumers: [UUID: Bool] = [:]
    private var timer: Timer?
    private var sleepReasons = Set<String>()
    private var systemObservers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for (event, reason, asleep) in [(NSWorkspace.screensDidSleepNotification, "display", true), (NSWorkspace.willSleepNotification, "system", true), (NSWorkspace.screensDidWakeNotification, "display", false), (NSWorkspace.didWakeNotification, "system", false)] {
            systemObservers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if asleep { self.sleepReasons.insert(reason) } else { self.sleepReasons.remove(reason) }
                    self.now = Date()
                    self.schedule()
                }
            })
        }
    }

    func acquire(_ id: UUID, seconds: Bool) {
        guard consumers[id] != seconds else { return }
        let wasIdle = consumers.isEmpty
        consumers[id] = seconds
        if wasIdle { now = Date() }
        schedule()
    }
    func release(_ id: UUID) {
        guard consumers.removeValue(forKey: id) != nil else { return }
        schedule()
    }
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard sleepReasons.isEmpty, !consumers.isEmpty else { return }
        let interval: TimeInterval = consumers.values.contains(true) ? 1 : 60
        let delay = interval - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: interval)
        let timer = Timer(timeInterval: max(delay, 0.01), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.schedule()
            }
        }
        timer.tolerance = interval == 1 ? 0.1 : 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
