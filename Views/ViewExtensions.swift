import SwiftUI
import AppKit

extension Color {
    static let primaryColor = Color(red: 0.6, green: 0.4, blue: 0.8)
}

/// Recognizes a deliberate rightward trackpad scroll without competing with vertical scrolling.
final class TrackpadBackSwipeRecognizer {
    // Lower than the former 220pt folder-only threshold while retaining enough travel
    // to avoid accidental navigation during ordinary diagonal scrolling.
    private static let minimumHorizontalDistance: CGFloat = 160
    private static let minimumHorizontalDominance: CGFloat = 3

    private var horizontalDistance: CGFloat = 0
    private var verticalDistance: CGFloat = 0

    func shouldNavigateBack(for event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas,
              event.momentumPhase.isEmpty else {
            reset()
            return false
        }

        guard event.phase == .began || event.phase == .changed || event.phase == .ended else {
            reset()
            return false
        }

        if event.phase == .began {
            reset()
        }

        guard event.phase != .ended else {
            reset()
            return false
        }

        let horizontalDelta = event.scrollingDeltaX
        guard horizontalDelta > 0 else {
            reset()
            return false
        }

        horizontalDistance += horizontalDelta
        verticalDistance += abs(event.scrollingDeltaY)

        guard horizontalDistance >= Self.minimumHorizontalDistance,
              horizontalDistance >= verticalDistance * Self.minimumHorizontalDominance else {
            return false
        }

        reset()
        return true
    }

    func reset() {
        horizontalDistance = 0
        verticalDistance = 0
    }
}

/// Routes one rightward trackpad gesture to the highest-priority active back action.
/// A single local event monitor prevents an underlying page from also handling the same gesture.
@MainActor
final class TrackpadBackSwipeRouter {
    static let shared = TrackpadBackSwipeRouter()

    private struct Handler {
        let priority: Int
        let isEnabled: () -> Bool
        let action: () -> Void
        let recognizer = TrackpadBackSwipeRecognizer()
    }

    private var handlers: [UUID: Handler] = [:]
    private var monitor: Any?
    private var activeHandlerID: UUID?

    private init() {}

    @discardableResult
    func register(
        priority: Int,
        isEnabled: @escaping () -> Bool,
        action: @escaping () -> Void
    ) -> UUID {
        let id = UUID()
        handlers[id] = Handler(priority: priority, isEnabled: isEnabled, action: action)
        installMonitorIfNeeded()
        return id
    }

    func unregister(_ id: UUID) {
        handlers[id]?.recognizer.reset()
        handlers[id] = nil
        if activeHandlerID == id {
            activeHandlerID = nil
        }
        removeMonitorIfUnused()
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeMonitorIfUnused() {
        guard handlers.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.hasPreciseScrollingDeltas,
              event.momentumPhase.isEmpty,
              let window = NSApp.keyWindow,
              window.sheetParent == nil,
              window.frame.contains(NSEvent.mouseLocation) else {
            resetActiveHandler()
            return event
        }

        guard event.phase == .began || event.phase == .changed || event.phase == .ended else {
            resetActiveHandler()
            return event
        }

        if event.phase == .began || activeHandlerID == nil {
            activeHandlerID = highestPriorityEnabledHandlerID()
        }

        guard let activeHandlerID,
              let handler = handlers[activeHandlerID],
              handler.isEnabled() else {
            resetActiveHandler()
            return event
        }

        guard event.phase != .ended else {
            resetActiveHandler()
            return event
        }

        guard handler.recognizer.shouldNavigateBack(for: event) else {
            return event
        }

        self.activeHandlerID = nil
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let handler = self.handlers[activeHandlerID],
                  handler.isEnabled() else {
                return
            }
            handler.action()
        }
        return nil
    }

    private func highestPriorityEnabledHandlerID() -> UUID? {
        handlers
            .filter { $0.value.isEnabled() }
            .max { $0.value.priority < $1.value.priority }?
            .key
    }

    private func resetActiveHandler() {
        if let activeHandlerID {
            handlers[activeHandlerID]?.recognizer.reset()
        }
        activeHandlerID = nil
    }
}
