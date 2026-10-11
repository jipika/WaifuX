import Foundation
@main struct PreferenceRegression {
    static func main() throws {
        let preferences = WaifuXPreferences.shared
        precondition(preferences.object(forKey: "nonexistent") == nil)
        preferences.set(true, forKey: "enabled")
        preferences.set(0.25, forKey: "volume")
        preferences.set("local", forKey: "source")
        precondition(preferences.bool(forKey: "enabled"))
        precondition(preferences.double(forKey: "volume") == 0.25)
        precondition(preferences.string(forKey: "source") == "local")
        preferences.removeObject(forKey: "source")
        precondition(preferences.object(forKey: "source") == nil)
        if BackgroundRuntimeRole.isHelper {
            preferences.migrateLegacyDomainIfNeeded(["oldKey": 42, "volume": 0.5])
            precondition(preferences.integer(forKey: "oldKey") == 42)
            precondition(preferences.double(forKey: "volume") == 0.25)
            preferences.migrateLegacyDomainIfNeeded(["oldKey": 100])
            precondition(preferences.integer(forKey: "oldKey") == 42)
            let pending = try preferences.pendingMutationData()
            precondition(pending.isEmpty)
            print("PASS durable Helper writes do not enter the UI retry overlay")
        } else {
            var mutations: [Data] = []
            let collector = Collector()
            preferences.setMutationHandler { collector.append($0) }
            mutations = collector.items
            precondition(mutations.count == 4)
            let deleted = try BackgroundPropertyList.decode(mutations.last!)
            precondition(deleted["removed"] as? Bool == true)
            let replay = try preferences.pendingMutationData().map(BackgroundPropertyList.decode)
            precondition(replay.count == 3)
            print("PASS quit retry collapses superseded writes to the latest value per key")
            let source = replay.first { $0["key"] as? String == "source" }!
            precondition(source["removed"] as? Bool == true && source["sequence"] as? NSNumber == deleted["sequence"] as? NSNumber && source["writerID"] as? String == deleted["writerID"] as? String)
            print("PASS removal retry preserves its original writer and sequence")
            preferences.acknowledgeMutation(key: "source", sequence: 3)
            let afterOldAck = try preferences.pendingMutationData()
            precondition(afterOldAck.count == 3)
            print("PASS an old acknowledgement does not erase the pending removal")
            preferences.acknowledgeMutation(key: "source", sequence: 4)
            let afterCurrentAck = try preferences.pendingMutationData().map(BackgroundPropertyList.decode)
            precondition(afterCurrentAck.count == 2)
            print("PASS the current acknowledgement clears only its committed setting")
            precondition(afterCurrentAck.first { $0["key"] as? String == "volume" }?["value"] as? NSNumber == NSNumber(value: 0.25))
            print("PASS retry serialization preserves a typed setting value")
            let suite = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SUITE"]!
            let disk = UserDefaults(suiteName: suite)!
            disk.set("saved", forKey: "durable")
            disk.synchronize()
            precondition(preferences.string(forKey: "durable") == "saved")
            let mutationCount = collector.items.count
            preferences.resetAfterHelperStopped()
            precondition(preferences.object(forKey: "durable") == nil)
            precondition(preferences.object(forKey: "volume") == nil)
            let afterReset = try preferences.pendingMutationData()
            precondition(afterReset.isEmpty)
            precondition(preferences.takeBufferedMutations().isEmpty)
            precondition(disk.persistentDomain(forName: suite)?.isEmpty != false)
            print("PASS data reset clears durable shared settings and pending UI edits")
            preferences.set("fresh", forKey: "fresh")
            precondition(collector.items.count == mutationCount)
            precondition(preferences.takeBufferedMutations().count == 1)
            print("PASS data reset removes the stale preference handler")
        }
        print("preferences regression passed role=\(BackgroundRuntimeRole.isHelper ? "helper" : "UI")")
    }
}
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ value: Data) { lock.lock(); values.append(value); lock.unlock() }
    var items: [Data] { lock.lock(); defer { lock.unlock() }; return values }
}
