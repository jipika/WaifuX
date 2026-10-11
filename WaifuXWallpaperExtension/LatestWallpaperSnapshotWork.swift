import Foundation

/// One heavy operation at a time. Each key retains only its latest pending input;
/// requests for other displays queue without cancelling the working display.
/// Cancellation never starts another decoder until the old operation returns.
final class LatestWallpaperSnapshotWork<Input: Sendable & Equatable, Output: Sendable>: @unchecked Sendable {
    typealias Reply = @Sendable (Output?) -> Void
    private struct State {
        var pendingInputs: [UInt32: Input] = [:]
        var pendingKeys: [UInt32] = []
        var workingKey: UInt32?
        var workingInput: Input?
        var operation: Task<Output, Never>?
        var worker: Task<Void, Never>?
        var workerID: UInt64?
        var nextWorkerID: UInt64 = 0
        var cachedInputs: [UInt32: Input] = [:]
        var cachedOutputs: [UInt32: Output] = [:]
        var cachedExpiry: [UInt32: TimeInterval] = [:]
        var cachedKeys: [UInt32] = []
        var replies: [UInt32: [Reply]] = [:]
        var replyCount = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let maximumReplies: Int
    private let perform: @Sendable (Input) async -> Output
    private let cacheIf: @Sendable (Output) -> Bool
    private let key: @Sendable (Input) -> UInt32
    private let maximumKeys: Int
    private let maximumCachedKeys: Int
    private let cacheLifetime: @Sendable (Output) -> TimeInterval
    private let clock: @Sendable () -> TimeInterval

    init(maximumReplies: Int = 32, maximumKeys: Int = 1, maximumCachedKeys: Int? = nil,
         key: @escaping @Sendable (Input) -> UInt32 = { _ in 0 },
         cacheIf: @escaping @Sendable (Output) -> Bool = { _ in true },
         cacheLifetime: @escaping @Sendable (Output) -> TimeInterval = { _ in .infinity },
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         perform: @escaping @Sendable (Input) async -> Output) {
        self.maximumReplies = max(0, maximumReplies)
        self.perform = perform
        self.cacheIf = cacheIf
        self.key = key
        self.maximumKeys = max(1, maximumKeys)
        self.maximumCachedKeys = max(0, min(maximumCachedKeys ?? maximumKeys, max(1, maximumKeys)))
        self.cacheLifetime = cacheLifetime
        self.clock = clock
    }

    func submit(_ input: Input, reply: Reply? = nil) {
        let inputKey = key(input)
        let now = clock()
        lock.lock()
        let keysInUse = state.pendingInputs.count + (state.workingKey != nil && state.pendingInputs[state.workingKey!] == nil ? 1 : 0)
        let keyInUse = state.pendingInputs[inputKey] != nil || state.workingKey == inputKey
        guard keyInUse || keysInUse < maximumKeys else {
            lock.unlock()
            reply?(nil)
            return
        }
        var immediateReply: Reply?
        var immediateOutput: Output?
        var hasImmediateReply = false
        let cacheValid = state.cachedInputs[inputKey] == input && (state.cachedExpiry[inputKey] ?? 0) > now
        let cached = !keyInUse && cacheValid
        if cached, let output = state.cachedOutputs[inputKey] {
            immediateReply = reply
            immediateOutput = output
            hasImmediateReply = true
        } else if let reply {
            if state.replyCount < maximumReplies {
                state.replies[inputKey, default: []].append(reply)
                state.replyCount += 1
            } else {
                // Do not retain arbitrarily many XPC reply closures under load.
                immediateReply = reply
                immediateOutput = cacheValid ? state.cachedOutputs[inputKey] : nil
                hasImmediateReply = true
            }
        }
        if !cached, !(state.workingKey == inputKey && state.workingInput == input && state.pendingInputs[inputKey] == nil) {
            if state.pendingInputs[inputKey] == nil { state.pendingKeys.append(inputKey) }
            state.pendingInputs[inputKey] = input
            state.cachedInputs.removeValue(forKey: inputKey)
            state.cachedOutputs.removeValue(forKey: inputKey)
            state.cachedExpiry.removeValue(forKey: inputKey)
            state.cachedKeys.removeAll { $0 == inputKey }
        }
        let obsolete = state.workingKey == inputKey && state.workingInput != input ? state.operation : nil
        let workerID: UInt64?
        if state.workerID == nil, !state.pendingKeys.isEmpty {
            state.nextWorkerID &+= 1
            workerID = state.nextWorkerID
            state.workerID = workerID
        } else {
            workerID = nil
        }
        lock.unlock()
        obsolete?.cancel()
        if hasImmediateReply { immediateReply?(immediateOutput) }
        guard let workerID else { return }
        let worker = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.drain(workerID: workerID)
        }
        lock.lock()
        if state.workerID == workerID { state.worker = worker }
        lock.unlock()
    }

    /// Keep lock operations in synchronous methods: no lock is held across an await.
    private func nextInput(workerID: UInt64) -> (key: UInt32, input: Input)? {
        lock.lock()
        defer { lock.unlock() }
        guard state.workerID == workerID, !state.pendingKeys.isEmpty else { return nil }
        let key = state.pendingKeys.removeFirst()
        guard let input = state.pendingInputs.removeValue(forKey: key) else { return nil }
        state.workingKey = key
        state.workingInput = input
        return (key, input)
    }

    private func install(_ operation: Task<Output, Never>, inputKey: UInt32, input: Input, workerID: UInt64) {
        lock.lock()
        let current = state.workerID == workerID && state.pendingInputs[inputKey] == nil
        if state.workerID == workerID {
            state.operation = operation
        }
        lock.unlock()
        if !current { operation.cancel() }
    }

    private func complete(_ output: Output, inputKey: UInt32, input: Input, cancelled: Bool, workerID: UInt64) -> (replies: [Reply], finished: Bool) {
        let shouldCache = cacheIf(output)
        let lifetime = cacheLifetime(output)
        let expiry = clock() + (lifetime.isNaN ? 0 : max(0, lifetime))
        lock.lock()
        defer { lock.unlock() }
        guard state.workerID == workerID else { return ([], true) }
        state.operation = nil
        state.workingInput = nil
        state.workingKey = nil
        var replies: [Reply] = []
        if state.pendingInputs[inputKey] == nil, !cancelled {
            if shouldCache, lifetime > 0 {
                state.cachedInputs[inputKey] = input
                state.cachedOutputs[inputKey] = output
                state.cachedExpiry[inputKey] = expiry
                state.cachedKeys.removeAll { $0 == inputKey }
                state.cachedKeys.append(inputKey)
                while state.cachedKeys.count > maximumCachedKeys {
                    let expired = state.cachedKeys.removeFirst()
                    state.cachedInputs.removeValue(forKey: expired)
                    state.cachedOutputs.removeValue(forKey: expired)
                    state.cachedExpiry.removeValue(forKey: expired)
                }
            }
            replies = state.replies.removeValue(forKey: inputKey) ?? []
            state.replyCount -= replies.count
        }
        let finished = state.pendingKeys.isEmpty
        if finished {
            state.worker = nil
            state.workerID = nil
        }
        return (replies, finished)
    }

    private func drain(workerID: UInt64) async {
        while let work = nextInput(workerID: workerID) {
            let perform = self.perform
            let operation = Task.detached(priority: .utility) { await perform(work.input) }
            install(operation, inputKey: work.key, input: work.input, workerID: workerID)
            let output = await operation.value
            let completion = complete(output, inputKey: work.key, input: work.input, cancelled: operation.isCancelled, workerID: workerID)
            for reply in completion.replies { reply(output) }
            if completion.finished { return }
        }
    }
}

/// Snapshot replies and BMP caching share this permit. Each coordinator admits
/// one operation, so production retains at most one waiting operation here.
/// Cancellation keeps the permit until decoding has actually returned.
actor WallpaperSnapshotDecodeGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingOperationCount: Int { waiters.count }

    func perform<Output: Sendable>(_ operation: @Sendable () async -> Output) async -> Output {
        await acquire()
        let output = await operation()
        release()
        return output
    }

    private func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}

let wallpaperSnapshotDecodeGate = WallpaperSnapshotDecodeGate()
