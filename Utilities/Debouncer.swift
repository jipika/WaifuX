// Debouncer.swift
// StorsWallpaper
//
// Created by StorsWallpaper on 2026.
//

@preconcurrency import Foundation
import os

// MARK: - Debouncer

/// A lightweight utility that coalesces rapid-fire invocations into a single
/// trailing-edge action after a specified delay.
///
/// Each call to ``debounce(action:)`` cancels any previously scheduled action
/// and schedules a new one. The action only executes after the full delay
/// elapses with no further calls.
///
/// ## Usage
/// ```swift
/// let debouncer = Debouncer(delay: 0.3)
///
/// // Only the last call within 300ms actually executes
/// debouncer.debounce { print("Hello") }
/// debouncer.debounce { print("World") }  // ← This one fires after 300ms
/// ```
///
/// ## Thread Safety
/// Mutable state is protected by an `OSAllocatedUnfairLock`, making the
/// debouncer safe to call from any thread or actor context — including
/// C callbacks (e.g. AXObserver) that lack Swift concurrency annotations.
final class Debouncer: @unchecked Sendable {

    // MARK: - Properties

    /// The debounce delay interval in seconds.
    private let delay: TimeInterval

    /// The dispatch queue on which debounced actions are executed.
    private let queue: DispatchQueue

    /// Lock-protected storage for the currently scheduled work item.
    private let _workItem = OSAllocatedUnfairLock<DispatchWorkItem?>(initialState: nil)

    private static let logger = Logger(
        subsystem: "com.waifux",
        category: "Debouncer"
    )

    // MARK: - Initialization

    /// Creates a new debouncer with the specified delay.
    ///
    /// - Parameters:
    ///   - delay: The time interval (in seconds) to wait after the last
    ///     invocation before executing the action.
    ///   - queue: The dispatch queue on which to execute the debounced action.
    ///     Defaults to `.main`.
    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    // MARK: - Public API

    /// Schedules an action to be executed after the debounce delay.
    ///
    /// If called again before the delay expires, the previous action is
    /// cancelled and the timer resets.
    ///
    /// - Parameter action: The closure to execute after the delay.
    func debounce(action: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem(block: action)
        _workItem.withLock { workItem in
            workItem?.cancel()
            workItem = item
        }
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancels any pending debounced action.
    func cancel() {
        _workItem.withLock { workItem in
            workItem?.cancel()
            workItem = nil
        }
    }
}

// MARK: - LeadingTrailingCoalescer

/// Coalesces event bursts into a gated leading callback and a settled trailing
/// callback. This is useful for window geometry events where we want a quick
/// first reaction plus one correction after the burst quiets down.
final class LeadingTrailingCoalescer: @unchecked Sendable {
    private let gateInterval: TimeInterval
    private let settleDelay: TimeInterval
    private let queue: DispatchQueue
    private let onLeading: @Sendable () -> Void
    private let onTrailing: @Sendable () -> Void

    private let lock = NSLock()
    private var lastLeadingFireTime: CFAbsoluteTime = 0
    private var trailingWorkItem: DispatchWorkItem?

    init(
        gateInterval: TimeInterval,
        settleDelay: TimeInterval,
        queue: DispatchQueue = .main,
        onLeading: @escaping @Sendable () -> Void,
        onTrailing: @escaping @Sendable () -> Void
    ) {
        self.gateInterval = gateInterval
        self.settleDelay = settleDelay
        self.queue = queue
        self.onLeading = onLeading
        self.onTrailing = onTrailing
    }

    func signal() {
        let now = CFAbsoluteTimeGetCurrent()
        var shouldFireLeading = false

        lock.lock()
        if now - lastLeadingFireTime >= gateInterval {
            lastLeadingFireTime = now
            shouldFireLeading = true
        }

        trailingWorkItem?.cancel()
        let trailing = DispatchWorkItem { [weak self] in
            self?.onTrailing()
        }
        trailingWorkItem = trailing
        lock.unlock()

        if shouldFireLeading {
            queue.async { [onLeading] in
                onLeading()
            }
        }
        queue.asyncAfter(deadline: .now() + settleDelay, execute: trailing)
    }

    func cancel() {
        lock.lock()
        trailingWorkItem?.cancel()
        trailingWorkItem = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        trailingWorkItem?.cancel()
        trailingWorkItem = nil
        lastLeadingFireTime = 0
        lock.unlock()
    }
}
