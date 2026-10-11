import Foundation

private struct Input: Hashable, Sendable {
    let display: UInt32
    let value: Int
}

private struct Output: Equatable, Sendable {
    let value: Int
    let cancelled: Bool
}

/// A deliberately cancellation-insensitive decoder: replacing a request must
/// wait until its work really returns, rather than trusting Task.cancel().
private actor ControlledDecoder {
    private var started: [Input] = []
    private var active = 0
    private var maximumActive = 0
    private var releases: [Input: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func decode(_ input: Input) async -> Output {
        active += 1
        maximumActive = max(maximumActive, active)
        started.append(input)
        await withCheckedContinuation { continuation in
            releases[input] = continuation
            let ready = observers.filter { started.count >= $0.0 }
            observers.removeAll { started.count >= $0.0 }
            for (_, observer) in ready { observer.resume() }
        }
        active -= 1
        return Output(value: input.value, cancelled: Task.isCancelled)
    }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func release(_ input: Input) {
        guard let continuation = releases.removeValue(forKey: input) else { preconditionFailure("decoder did not start") }
        continuation.resume()
    }

    func starts() -> [Input] { started }
    func maximumConcurrency() -> Int { maximumActive }
}

private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Output?] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func receive(_ output: Output?) {
        lock.lock()
        outputs.append(output)
        let ready = observers.filter { outputs.count >= $0.0 }
        observers.removeAll { outputs.count >= $0.0 }
        lock.unlock()
        for (_, observer) in ready { observer.resume() }
    }

    func wait(_ count: Int = 1) async {
        await withCheckedContinuation { register(count, continuation: $0) }
    }

    private func register(_ count: Int, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let ready = outputs.count >= count
        if !ready { observers.append((count, continuation)) }
        lock.unlock()
        if ready { continuation.resume() }
    }

    func values() -> [Output?] {
        lock.lock()
        defer { lock.unlock() }
        return outputs
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func read() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }; return time
    }
    func set(_ value: TimeInterval) {
        lock.lock(); time = value; lock.unlock()
    }
}

@main
private struct WallpaperSnapshotWorkRegression {
    static func main() async {
        await latestSnapshot()
        await boundedReplies()
        await independentDisplays()
        await boundedDisplayCache()
        await boundedDisplays()
        await failureCooldown()
        await sharedDecodePermit()
        pixelBudget()
    }

    private static func latestSnapshot() async {
        let decoder = ControlledDecoder()
        let work = LatestWallpaperSnapshotWork<Input, Output> { await decoder.decode($0) }
        let a = Input(display: 1, value: 1), b = Input(display: 1, value: 2), c = Input(display: 1, value: 3)
        let replies = Replies()
        work.submit(a) { replies.receive($0) }
        await decoder.waitForStarts(1)
        work.submit(b) { replies.receive($0) }
        work.submit(c) { replies.receive($0) }
        await decoder.release(a)
        await decoder.waitForStarts(2)
        let starts = await decoder.starts()
        precondition(starts == [a, c])
        await decoder.release(c)
        await replies.wait(3)
        precondition(replies.values().allSatisfy { $0?.value == 3 && $0?.cancelled == false })
        let cached = Replies()
        work.submit(c) { cached.receive($0) }
        await cached.wait()
        let count = await decoder.starts().count
        let maximum = await decoder.maximumConcurrency()
        precondition(count == 2 && maximum == 1 && cached.values()[0]?.value == 3)
        print("PASS latest snapshot coalesces requests, rejects stale output and reuses its successful surface")
    }

    private static func boundedReplies() async {
        let decoder = ControlledDecoder()
        let work = LatestWallpaperSnapshotWork<Input, Output>(maximumReplies: 2) { await decoder.decode($0) }
        let input = Input(display: 1, value: 4)
        let retained = Replies(), overflow = Replies()
        work.submit(input) { retained.receive($0) }
        await decoder.waitForStarts(1)
        work.submit(input) { retained.receive($0) }
        work.submit(input) { overflow.receive($0) }
        await overflow.wait()
        precondition(overflow.values()[0] == nil)
        await decoder.release(input)
        await retained.wait(2)
        precondition(retained.values().allSatisfy { $0?.value == 4 })
        print("PASS retained XPC reply closures have a fixed cap")
    }

    private static func independentDisplays() async {
        let decoder = ControlledDecoder()
        let work = LatestWallpaperSnapshotWork<Input, Output>(maximumKeys: 2, key: { $0.display }) { await decoder.decode($0) }
        let a1 = Input(display: 1, value: 10), a2 = Input(display: 1, value: 11), b = Input(display: 2, value: 20)
        let aReplies = Replies(), bReplies = Replies()
        work.submit(a1) { aReplies.receive($0) }
        await decoder.waitForStarts(1)
        work.submit(b) { bReplies.receive($0) }
        work.submit(a2) { aReplies.receive($0) }
        await decoder.release(a1)
        await decoder.waitForStarts(2)
        let secondStarts = await decoder.starts()
        precondition(secondStarts == [a1, b])
        await decoder.release(b)
        await bReplies.wait()
        await decoder.waitForStarts(3)
        await decoder.release(a2)
        await aReplies.wait(2)
        let starts = await decoder.starts()
        let maximum = await decoder.maximumConcurrency()
        precondition(starts == [a1, b, a2] && maximum == 1)
        precondition(bReplies.values()[0]?.value == 20 && bReplies.values()[0]?.cancelled == false)
        precondition(aReplies.values().allSatisfy { $0?.value == 11 && $0?.cancelled == false })
        print("PASS two displays both finish while a replaced display discards its old completion")

        let another = ControlledDecoder()
        let independent = LatestWallpaperSnapshotWork<Input, Output>(maximumKeys: 2, key: { $0.display }) { await another.decode($0) }
        let retained = Replies()
        independent.submit(a1) { retained.receive($0) }
        await another.waitForStarts(1)
        independent.submit(b)
        await another.release(a1)
        await retained.wait()
        precondition(retained.values()[0]?.cancelled == false)
        await another.waitForStarts(2)
        await another.release(b)
        print("PASS another display's request never cancels the working display")
    }

    private static func boundedDisplayCache() async {
        let decoder = ControlledDecoder()
        let work = LatestWallpaperSnapshotWork<Input, Output>(maximumKeys: 2, maximumCachedKeys: 1,
                                                               key: { $0.display }) { await decoder.decode($0) }
        let a = Input(display: 1, value: 10), b = Input(display: 2, value: 20)
        let first = Replies(), second = Replies(), cached = Replies(), rebuilt = Replies()
        work.submit(a) { first.receive($0) }
        await decoder.waitForStarts(1)
        work.submit(b) { second.receive($0) }
        await decoder.release(a)
        await first.wait()
        await decoder.waitForStarts(2)
        await decoder.release(b)
        await second.wait()
        precondition(first.values()[0]?.value == 10 && second.values()[0]?.value == 20)
        work.submit(b) { cached.receive($0) }
        await cached.wait()
        let startsBeforeEviction = await decoder.starts()
        precondition(startsBeforeEviction == [a, b] && cached.values()[0]?.value == 20)
        work.submit(a) { rebuilt.receive($0) }
        await decoder.waitForStarts(3)
        await decoder.release(a)
        await rebuilt.wait()
        let startsAfterEviction = await decoder.starts()
        precondition(startsAfterEviction == [a, b, a] && rebuilt.values()[0]?.value == 10)
        print("PASS display replies stay separate while the completed cache retains only one display")
    }

    private static func boundedDisplays() async {
        let decoder = ControlledDecoder()
        let work = LatestWallpaperSnapshotWork<Input, Output>(maximumKeys: 2, key: { $0.display }) { await decoder.decode($0) }
        let a = Input(display: 1, value: 1), b = Input(display: 2, value: 2), c = Input(display: 3, value: 3)
        let rejected = Replies(), completed = Replies()
        work.submit(a)
        await decoder.waitForStarts(1)
        work.submit(b) { completed.receive($0) }
        work.submit(c) { rejected.receive($0) }
        await rejected.wait()
        precondition(rejected.values()[0] == nil)
        await decoder.release(a)
        await decoder.waitForStarts(2)
        await decoder.release(b)
        await completed.wait()
        let starts = await decoder.starts()
        precondition(starts == [a, b])
        print("PASS active and pending display keys stay within their configured bound")
    }

    private static func failureCooldown() async {
        let decoder = ControlledDecoder(), clock = TestClock()
        let work = LatestWallpaperSnapshotWork<Input, Output>(cacheLifetime: { $0.value < 0 ? 5 : .infinity },
                                                             clock: { clock.read() }) { await decoder.decode($0) }
        let failure = Input(display: 1, value: -1), success = Input(display: 1, value: 1)
        let first = Replies(), cooldown = Replies(), retried = Replies(), succeeded = Replies(), reused = Replies()
        work.submit(failure) { first.receive($0) }
        await decoder.waitForStarts(1)
        await decoder.release(failure)
        await first.wait()
        clock.set(102)
        work.submit(failure) { cooldown.receive($0) }
        await cooldown.wait()
        let beforeRetry = await decoder.starts().count
        precondition(beforeRetry == 1)
        clock.set(106)
        work.submit(failure) { retried.receive($0) }
        await decoder.waitForStarts(2)
        await decoder.release(failure)
        await retried.wait()
        work.submit(success) { succeeded.receive($0) }
        await decoder.waitForStarts(3)
        await decoder.release(success)
        await succeeded.wait()
        clock.set(1_000_000)
        work.submit(success) { reused.receive($0) }
        await reused.wait()
        let afterReuse = await decoder.starts().count
        precondition(afterReuse == 3)
        print("PASS failures retry after a short cooldown while successful snapshots remain reusable")
    }

    private static func sharedDecodePermit() async {
        let decoder = ControlledDecoder(), gate = WallpaperSnapshotDecodeGate()
        let a = Input(display: 1, value: 1), b = Input(display: 2, value: 2)
        let first = Task { await gate.perform { await decoder.decode(a) } }
        await decoder.waitForStarts(1)
        let second = Task { await gate.perform { await decoder.decode(b) } }
        var queued = false
        for _ in 0..<10_000 {
            if await gate.waitingOperationCount == 1 { queued = true; break }
            await Task.yield()
        }
        precondition(queued)
        first.cancel()
        let before = await decoder.starts()
        precondition(before == [a])
        await decoder.release(a)
        await decoder.waitForStarts(2)
        await decoder.release(b)
        _ = await first.value
        _ = await second.value
        let maximum = await decoder.maximumConcurrency()
        precondition(maximum == 1)
        print("PASS snapshot and BMP share one decoder permit even when cancellation is ignored")
    }

    private static func pixelBudget() {
        let budget = WallpaperSnapshotPixelBudget.maximumPixelBytes
        let fourK = WallpaperSnapshotPixelBudget.layout(width: 3840, height: 2160)!
        precondition(fourK.width == 3840 && fourK.height == 2160 && fourK.allocationBytes <= budget)
        let huge = WallpaperSnapshotPixelBudget.layout(width: 1e100, height: 1e100)!
        precondition(huge.width <= 4096 && huge.height <= 4096 && huge.allocationBytes <= budget)
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            precondition(WallpaperSnapshotPixelBudget.layout(width: invalid, height: 100) == nil)
        }
        precondition(WallpaperSnapshotPixelBudget.layout(width: Double.greatestFiniteMagnitude, height: 2) == nil)
        precondition(!WallpaperSnapshotPixelBudget.accepts(width: 2, height: 4096, bytesPerRow: Int.max))
        precondition(!WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: 5000, height: 1, bytesPerRow: 20_000))
        print("PASS finite dimensions, large metadata and checked stride multiplication enforce the pixel budget")

        let aligned = WallpaperSnapshotPixelBudget.layout(width: 4095, height: 4095,
                                                          rowAlignment: 512, allocationAlignment: 4096)!
        precondition(aligned.bytesPerRow % 512 == 0 && aligned.allocationBytes % 4096 == 0 && aligned.allocationBytes <= budget)
        let hdr = WallpaperSnapshotPixelBudget.layout(width: 3840, height: 2160, decodedBytesPerPixel: 16)!
        precondition(hdr.width * hdr.height * 16 <= budget)
        let dimension = WallpaperSnapshotPixelBudget.maximumVideoImageDimension
        precondition(dimension * dimension * 16 <= budget)
        precondition(WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: dimension, height: dimension, bytesPerRow: dimension * 16))
        print("PASS system-style alignment and worst-case HDR pixels fit the allocation budget")
    }
}
