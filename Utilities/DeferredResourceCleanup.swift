import Foundation

/// A completion/cancellation hook must release its captured resources once,
/// even when both a timeout and a cancellation reach it.
@MainActor
final class SingleUseAction {
    private var action: (@MainActor () -> Void)?

    init(_ action: @escaping @MainActor () -> Void) { self.action = action }

    func perform() {
        let action = action
        self.action = nil
        action?()
    }

    func discard() { action = nil }
}

/// Holds retired resources through a short cleanup grace period. Work items are
/// indexed by value tokens so their closures never retain their own work item.
@MainActor
final class DeferredResourceCleanup {
    private var workItems: [UUID: DispatchWorkItem] = [:]

    var count: Int { workItems.count }
    var isEmpty: Bool { workItems.isEmpty }

    func retain<Resource>(
        _ resources: [Resource],
        for duration: TimeInterval,
        beforeRelease: @escaping @MainActor ([Resource]) -> Void = { _ in }
    ) {
        guard !resources.isEmpty else { return }
        let token = UUID()
        let workItem = DispatchWorkItem { [weak self, resources] in
            // This work item is submitted only to the main dispatch queue.
            MainActor.assumeIsolated {
                beforeRelease(resources)
                self?.workItems.removeValue(forKey: token)
            }
        }
        workItems[token] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, duration),
            execute: workItem
        )
    }

    func cancelAll() {
        workItems.values.forEach { $0.cancel() }
        workItems.removeAll()
        // The main queue releases canceled work items when their short deadline
        // passes. There is no work item -> captured work item ownership cycle.
    }
}
