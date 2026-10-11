import Foundation

/// Helper owns durable writes. UI edits remain visible immediately in a local
/// overlay until the Helper commits and acknowledges the mutation.
final class WaifuXPreferences: UserDefaults, @unchecked Sendable {
    // UserDefaults' SDK Sendable conformance is unavailable in Release WMO.
    // Access to this singleton's added mutable state is protected by stateLock.
    nonisolated(unsafe) static let shared = WaifuXPreferences()

    private let stateLock = NSRecursiveLock()
    private var pending: [String: (sequence: UInt64, value: Any?)] = [:]
    private var legacy: [String: Any] = [:]
    private var sequence: UInt64 = 0
    private let writerID = UUID().uuidString
    private var mutationHandler: (@Sendable (Data) -> Void)?
    private var bufferedMutations: [Data] = []
    private let preferencesSuite: String

    private init() {
        let suite = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SUITE"]
            ?? BackgroundAgentWire.preferencesSuite
        preferencesSuite = suite
        super.init(suiteName: suite)!
    }

    /// Data reset runs in the UI only after the Helper has stopped, so no
    /// background writer can repopulate the removed preferences or files.
    func resetAfterHelperStopped() {
        precondition(BackgroundRuntimeRole.isRemoteUI)
        stateLock.lock()
        defer { stateLock.unlock() }
        pending.removeAll()
        legacy.removeAll()
        bufferedMutations.removeAll()
        mutationHandler = nil
        super.removePersistentDomain(forName: preferencesSuite)
        if !BackgroundRuntimeRole.isIsolatedTest {
            UserDefaults.standard.removePersistentDomain(forName: "com.waifux.app")
            UserDefaults.standard.synchronize()
        }
        super.synchronize()
    }

    func loadLegacyPreferences() {
        guard BackgroundRuntimeRole.isRemoteUI else { return }
        stateLock.lock()
        legacy = UserDefaults.standard.persistentDomain(forName: "com.waifux.app") ?? [:]
        stateLock.unlock()
    }

    func takeBufferedMutations() -> [Data] {
        stateLock.lock()
        let values = bufferedMutations
        bufferedMutations.removeAll()
        stateLock.unlock()
        return values
    }

    func setMutationHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        stateLock.lock()
        mutationHandler = handler
        let buffered = bufferedMutations
        bufferedMutations.removeAll()
        stateLock.unlock()
        buffered.forEach(handler)
    }

    func acknowledgeMutation(key: String, sequence: UInt64) {
        super.synchronize()
        stateLock.lock()
        if let item = pending[key], item.sequence <= sequence {
            pending.removeValue(forKey: key)
        }
        stateLock.unlock()
    }

    /// Retry unacknowledged edits using their original writer/sequence. A quit
    /// retry must not lose the last setting when the prior connection failed.
    func pendingMutationData() throws -> [Data] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try pending.keys.sorted().map { key in
            let item = pending[key]!
            var mutation: [String: Any] = ["key": key, "sequence": NSNumber(value: item.sequence),
                                          "writerID": writerID, "removed": item.value == nil]
            if let value = item.value { mutation["value"] = value }
            return try BackgroundPropertyList.encode(mutation)
        }
    }

    override func object(forKey defaultName: String) -> Any? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let item = pending[defaultName] { return item.value }
        if let value = super.object(forKey: defaultName) { return value }
        return (super.object(forKey: BackgroundAgentWire.migrationKey) as? NSNumber)?.boolValue == true ? nil : legacy[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard BackgroundRuntimeRole.isRemoteUI else {
            super.set(value, forKey: defaultName)
            return
        }
        stateLock.lock()
        sequence &+= 1
        let mutationSequence = sequence
        pending[defaultName] = (mutationSequence, value)
        var mutation: [String: Any] = [
            "key": defaultName, "sequence": NSNumber(value: mutationSequence),
            "writerID": writerID, "removed": value == nil
        ]
        if let value { mutation["value"] = value }
        if let data = try? BackgroundPropertyList.encode(mutation) {
            if let handler = mutationHandler { handler(data) }
            else { bufferedMutations.append(data) }
        }
        stateLock.unlock()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func removeObject(forKey defaultName: String) { set(nil, forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url?.absoluteString, forKey: defaultName) }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey defaultName: String) -> Float { (object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0 }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func url(forKey defaultName: String) -> URL? {
        guard let string = string(forKey: defaultName) else { return nil }
        return URL(string: string)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        var values = ((super.object(forKey: BackgroundAgentWire.migrationKey) as? NSNumber)?.boolValue == true ? [:] : legacy).merging(super.dictionaryRepresentation()) { _, new in new }
        for (key, item) in pending { values[key] = item.value }
        return values
    }

    /// Called only by Helper before any runtime service is restored.
    func migrateLegacyDomainIfNeeded(_ values: [String: Any]) {
        guard BackgroundRuntimeRole.isHelper, (super.object(forKey: BackgroundAgentWire.migrationKey) as? NSNumber)?.boolValue != true else { return }
        for (key, value) in values where key != BackgroundAgentWire.migrationKey {
            if super.object(forKey: key) == nil { super.set(value, forKey: key) }
        }
        super.set(true, forKey: BackgroundAgentWire.migrationKey)
        super.synchronize()
    }
}
