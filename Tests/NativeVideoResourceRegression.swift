import Foundation
import CoreGraphics

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func recordRelease() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class RetiredResource {
    let counter: ReleaseCounter
    init(_ counter: ReleaseCounter) { self.counter = counter }
    deinit { counter.recordRelease() }
}

private final class WeakResource {
    weak var value: RetiredResource?
    init(_ value: RetiredResource) { self.value = value }
}

private enum RegressionFailure: Error { case failed(String) }

@main
private struct NativeVideoResourceRegression {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw RegressionFailure.failed(name) }
            checks += 1
            print("PASS \(name)")
        }

        // Pure arithmetic: no bitmap, player, NSWindow, screenshot, or IOSurface
        // is allocated by any of these geometry cases.
        let hd = VideoFreezeFrameBudget.allocation(viewportSize: CGSize(width: 1_920, height: 1_080), backingScale: 1)
        try expect(hd?.pixelWidth == 1_920 && hd?.pixelHeight == 1_080, "ordinary viewport keeps native pixels")
        for (name, size, scale) in [
            ("5K Retina", CGSize(width: 2_560, height: 1_440), CGFloat(2)),
            ("8K", CGSize(width: 7_680, height: 4_320), CGFloat(1)),
            ("extreme panorama", CGSize(width: 1_000_000, height: 1_080), CGFloat(2)),
            ("huge finite geometry", CGSize(width: 1e100, height: 1e100), CGFloat(1)),
        ] {
            let allocation = VideoFreezeFrameBudget.allocation(viewportSize: size, backingScale: scale)
            try expect(allocation != nil, "\(name) obtains a bounded snapshot plan")
            try expect(allocation!.byteCount <= VideoFreezeFrameBudget.maximumBytes &&
                       allocation!.pixelWidth <= VideoFreezeFrameBudget.maximumDimension &&
                       allocation!.pixelHeight <= VideoFreezeFrameBudget.maximumDimension,
                       "\(name) respects bytes and dimensions")
        }
        try expect(VideoFreezeFrameBudget.allocation(viewportSize: CGSize(width: CGFloat.infinity, height: 100), backingScale: 2) == nil,
                   "infinite geometry refused before integer conversion")
        try expect(VideoFreezeFrameBudget.allocation(viewportSize: CGSize(width: CGFloat.nan, height: 100), backingScale: 2) == nil,
                   "NaN geometry refused")
        try expect(VideoFreezeFrameBudget.allocation(viewportSize: CGSize(width: 100, height: 100), backingScale: -1) == nil,
                   "negative backing scale refused")
        try expect(VideoFreezeFrameBudget.allocation(viewportSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 100), backingScale: 2) == nil,
                   "floating point multiplication overflow refused")

        // LRU uses integer costs, never images. Simulate oversized posters and
        // long rotation while checking both aggregate bytes and entry limits.
        try expect(VideoPosterCacheBudget.decodedByteCount(bytesPerRow: Int.max, height: 2) == nil,
                   "decoded cost overflow refused")
        try expect(VideoPosterCacheBudget.decodedByteCount(bytesPerRow: 16_384, height: 2_048) == nil,
                   "single poster exceeding pixel budget refused")
        var posterBudget = VideoPosterCacheBudget()
        for index in 0..<100 {
            _ = posterBudget.insert("large-\(index)", decodedBytes: VideoPosterCacheBudget.maximumImageBytes)
        }
        try expect(posterBudget.byteCount <= VideoPosterCacheBudget.maximumDecodedBytes && posterBudget.count == 4,
                   "large poster rotation stays within 64 MiB")
        _ = posterBudget.insert("large-99", decodedBytes: 4)
        try expect(posterBudget.byteCount == 3 * VideoPosterCacheBudget.maximumImageBytes + 4,
                   "replaced poster cost is subtracted")
        var smallPosterBudget = VideoPosterCacheBudget()
        for index in 0..<24 { _ = smallPosterBudget.insert("small-\(index)", decodedBytes: 4) }
        smallPosterBudget.touch("small-0")
        let evicted = smallPosterBudget.insert("small-24", decodedBytes: 4)
        try expect(evicted == ["small-1"] && smallPosterBudget.count == 24,
                   "least recently used poster evicted at entry budget")
        let refused = smallPosterBudget.insert("small-0", decodedBytes: Int.max)
        try expect(refused == ["small-0"] && smallPosterBudget.count == 23,
                   "invalid replacement releases previous cached cost")

        // Actual production deferred-retention code, exercised with tiny Swift
        // resources. Deinitialization proves the captures do not form a cycle.
        let counter = ReleaseCounter()
        let completed = DeferredResourceCleanup()
        var weakResources: [WeakResource] = []
        for _ in 0..<100 {
            let resource = RetiredResource(counter)
            weakResources.append(WeakResource(resource))
            completed.retain([resource], for: 0.02)
        }
        try expect(weakResources.allSatisfy { $0.value != nil }, "grace period retains retired resources")
        try await Task.sleep(for: .milliseconds(100))
        try expect(completed.isEmpty && weakResources.allSatisfy { $0.value == nil } && counter.count == 100,
                   "completed cleanup releases every retired resource")

        let canceled = DeferredResourceCleanup()
        weak var canceledResource: RetiredResource?
        do {
            let resource = RetiredResource(counter)
            canceledResource = resource
            canceled.retain([resource], for: 0.02)
        }
        canceled.cancelAll()
        try expect(canceled.isEmpty, "canceled cleanup removes pending entries")
        try await Task.sleep(for: .milliseconds(100))
        try expect(canceledResource == nil && counter.count == 101, "canceled work item releases captured resource after deadline")

        var abandoned: DeferredResourceCleanup? = DeferredResourceCleanup()
        weak var abandonedResource: RetiredResource?
        do {
            let resource = RetiredResource(counter)
            abandonedResource = resource
            abandoned?.retain([resource], for: 0.02)
        }
        abandoned = nil
        try await Task.sleep(for: .milliseconds(100))
        try expect(abandonedResource == nil && counter.count == 102,
                   "cleanup store deallocation does not strand retained resource")
        var cancelCalls = 0
        let cancelAction = SingleUseAction { cancelCalls += 1 }
        cancelAction.perform()
        cancelAction.perform()
        try expect(cancelCalls == 1, "transition cancellation hook runs once")
        let completedAction = SingleUseAction { cancelCalls += 1 }
        completedAction.discard()
        completedAction.perform()
        try expect(cancelCalls == 1, "completed transition cannot run its cancellation hook")

        // Exercise the same shared one-shot resource closure used by global
        // crossfades with a partially promoted P/A owner graph. These are tiny
        // Swift objects, not media players or WindowServer surfaces.
        let globalCounter = ReleaseCounter()
        var visibleOwners: [String: RetiredResource] = [:]
        var globalCleanup: SingleUseAction?
        weak var visibleP: RetiredResource?
        weak var visibleA: RetiredResource?
        var consumedSourceCount = 0
        do {
            let p = RetiredResource(globalCounter)
            let a = RetiredResource(globalCounter)
            visibleP = p
            visibleA = a
            visibleOwners = ["left": a, "right": p]
            let actualSourceSnapshot = [p, a]
            globalCleanup = SingleUseAction { [actualSourceSnapshot] in
                consumedSourceCount += actualSourceSnapshot.count
            }
        }
        let leftCancellation = SingleUseAction { globalCleanup?.perform() }
        let rightCancellation = SingleUseAction { globalCleanup?.perform() }
        leftCancellation.perform()
        rightCancellation.perform()
        try expect(consumedSourceCount == 2, "multiple display cancellations consume shared source snapshot once")
        try expect(visibleP != nil && visibleA != nil && globalCounter.count == 0,
                   "canceling snapshot retention preserves still-visible P/A owners")
        visibleOwners.removeValue(forKey: "right")
        try expect(visibleP == nil && visibleA != nil && globalCounter.count == 1,
                   "retired P releases immediately while promoted A remains visible")
        visibleOwners.removeAll()
        try expect(visibleA == nil && globalCounter.count == 2,
                   "completed or canceled shared cleanup does not retain abandoned pipelines")

        // Source guards cover the actual AppKit ownership boundary without
        // constructing AVPlayer, NSWindow, or exercising desktop rendering.
        // These checks verify ordering and identities, not media framework behavior.
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Services/VideoWallpaperManager.swift")
        let managerSource = try String(contentsOf: managerURL, encoding: .utf8)
        func sourceSection(from start: String, until end: String) throws -> String {
            guard let startRange = managerSource.range(of: start),
                  let endRange = managerSource.range(
                    of: end, range: startRange.upperBound..<managerSource.endIndex
                  ) else { throw RegressionFailure.failed("missing native lifecycle source section: \(start)") }
            return String(managerSource[startRange.lowerBound..<endRange.lowerBound])
        }
        let applyCancellation = try sourceSection(
            from: "// A newer apply supersedes", until: "let captureScreens: [NSScreen]"
        )
        try expect(applyCancellation.contains("pendingGlobalTransitionPlayer != nil || globalTransitionResourceCleanup != nil"),
                   "new apply cancels committed global owners after pending player promotion")
        let rebuildSource = try sourceSection(
            from: "private func rebuildWindows(", until: "private func stageGlobalSharedVideoTransition("
        )
        let singleScreenCancel = rebuildSource.range(of: "cancelPendingGlobalVideoTransition(reason: \"supersededBySingleScreenRebuild\")")
        let assignment = rebuildSource.range(of: "assignPlayerComponents(components, to: targetScreenID)")
        try expect(singleScreenCancel != nil && assignment != nil && singleScreenCancel!.lowerBound < assignment!.lowerBound,
                   "single-screen rebuild cancels global reconciliation before assigning incoming player")
        let cancellationSource = try sourceSection(
            from: "let cancelReplacement: @MainActor", until: "let finalizeReplacement: @MainActor"
        )
        try expect(cancellationSource.contains("if self.playerItemObserverTokens[targetScreenID] == readinessToken {") &&
                   cancellationSource.contains("self.playerItemObservers.removeValue(forKey: targetScreenID)?.invalidate()") &&
                   cancellationSource.contains("self.fadeInTimeouts.removeValue(forKey: targetScreenID)?.cancel()"),
                   "replacement cancellation invalidates only its matching readiness UUID")
        let readinessSource = try sourceSection(
            from: "let beginAnimatedSwap: @MainActor", until: "let observer = incomingLayer.observe"
        )
        let readinessGuard = readinessSource.range(of: "incomingLayer.player === components.player else {")
        let attachEntry = readinessSource.range(of: "containerView.crossfadePreparedPlayer(")
        try expect(readinessSource.contains("self.players[targetScreenID] === components.player") &&
                   readinessSource.contains("self.windows[targetScreenID] === existingWindow") &&
                   readinessSource.contains("existingWindow.contentView === containerView") &&
                   readinessGuard != nil && attachEntry != nil && readinessGuard!.lowerBound < attachEntry!.lowerBound,
                   "late readiness cannot reattach canceled player before ownership checks")
        print("Native video resource regression: \(checks) checks passed; no desktop rendering")
    }
}
