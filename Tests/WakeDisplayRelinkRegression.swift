import Foundation

/// Production ownership resolver + transactions; no windows, players or IPC.
@main
enum WakeDisplayRelinkRegression {
    typealias Screen = (id: String, fingerprint: String)
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    struct Saved {
        var config = SchedulerConfig.default
        var lastItems: [String: String] = [:]
        var rounds: [String: Set<String>] = [:]
        var deadlines: [String: Date] = [:]
        var fingerprints: [String: String] {
            config.displayConfigs.compactMapValues(\.displayFingerprint)
        }
        mutating func reconnect(_ screens: [Screen], settled: Bool = true) {
            let bindings = WallpaperScreenIdentity.schedulerBindings(
                fingerprints: fingerprints, screens: screens, allowRelativeRank: settled
            )
            let moves = WallpaperScreenIdentity.schedulerRelocations(
                keys: Set(config.displayConfigs.keys), bindings: bindings, liveIDs: Set(screens.map(\.id))
            )
            check(Set(moves.values).count == moves.count, "migration destinations must be unique")
            config.displayConfigs = WallpaperScreenIdentity.relocatingSchedulerValues(config.displayConfigs, using: moves)
            lastItems = WallpaperScreenIdentity.relocatingSchedulerValues(lastItems, using: moves)
            rounds = WallpaperScreenIdentity.relocatingSchedulerValues(rounds, using: moves)
            deadlines = WallpaperScreenIdentity.relocatingSchedulerValues(deadlines, using: moves)
            for (_, liveID) in bindings {
                config.displayConfigs[liveID]?.displayFingerprint = screens.first { $0.id == liveID }!.fingerprint
            }
        }
        mutating func reboot() throws {
            config = try JSONDecoder().decode(SchedulerConfig.self, from: JSONEncoder().encode(config))
            lastItems = try PropertyListDecoder().decode([String: String].self, from: PropertyListEncoder().encode(lastItems))
            rounds = try JSONDecoder().decode([String: Set<String>].self, from: JSONEncoder().encode(rounds))
            deadlines = try PropertyListDecoder().decode([String: Date].self, from: PropertyListEncoder().encode(deadlines))
        }
    }

    static func fixture(_ screens: [Screen]) -> Saved {
        var result = Saved()
        for (index, screen) in screens.enumerated() {
            var config = DisplaySchedulerConfig.fromLegacy(.default)
            config.isEnabled = true
            config.folderIDs = ["folder-\(index)"]
            config.displayFingerprint = screen.fingerprint
            result.config.displayConfigs[screen.id] = config
            result.lastItems[screen.id] = "item-\(index)"
            result.rounds[screen.id] = ["item-\(index)", "older-\(index)"]
            result.deadlines[screen.id] = Date(timeIntervalSince1970: Double(index + 100))
        }
        return result
    }

    static func assertOwner(_ saved: Saved, id: String, owner: Int) {
        check(saved.config.displayConfigs[id]?.folderIDs == ["folder-\(owner)"], "folder follows physical owner \(owner) at \(id)")
        check(saved.lastItems[id] == "item-\(owner)", "last item follows owner")
        check(saved.rounds[id] == ["item-\(owner)", "older-\(owner)"], "random round follows owner")
        check(saved.deadlines[id] == Date(timeIntervalSince1970: Double(owner + 100)), "deadline follows owner")
    }

    static func main() throws {
        // Models observed in the supplied log. P20 may renegotiate resolution.
        let original: [Screen] = [
            ("1", "cg:1138:4054:1427112294:external"),
            ("2", "cg:19608:10120:1:external"),
            ("3", "cg:7892:10276:noserial:Kuycon P20:2560x1440:external:position:1920x0")
        ]
        let ids = ["1", "2", "3"]
        for a in ids {
            for b in ids where b != a {
                let c = ids.first { $0 != a && $0 != b }!
                let current: [Screen] = [
                    (a, original[0].fingerprint), (b, original[1].fingerprint),
                    (c, "cg:7892:10276:noserial:Kuycon P20:3840x2160:external:position:-3840x0")
                ]
                var saved = fixture(original)
                saved.reconnect(Array(current.reversed()))
                assertOwner(saved, id: a, owner: 0)
                assertOwner(saved, id: b, owner: 1)
                assertOwner(saved, id: c, owner: 2)
                try saved.reboot()
                saved.reconnect(current)
                assertOwner(saved, id: a, owner: 0)
                assertOwner(saved, id: b, owner: 1)
                assertOwner(saved, id: c, owner: 2)
                check(saved.config.displayConfigs.count == 3, "swaps/cycles preserve all records")
            }
        }

        var gradual = fixture(original)
        let final: [Screen] = [("2", original[0].fingerprint), ("3", original[1].fingerprint), ("1", original[2].fingerprint)]
        for subset in [[], [final[2]], [final[2], final[0]], [final[2]], final] {
            gradual.reconnect(subset)
            try gradual.reboot()
            check(gradual.config.displayConfigs.count == 3, "partial wake must retain offline folders")
        }
        for index in final.indices { assertOwner(gradual, id: final[index].id, owner: index) }

        var replacement = fixture(original)
        replacement.reconnect([("1", "cg:999:999:123:external")])
        check(replacement.config.displayConfigs["1"] == nil, "new owner of reused ID gets no old folders")
        check(replacement.config.displayConfigs.count == 3, "replacement parks all old owners")
        try replacement.reboot()
        replacement.reconnect(original)
        for index in original.indices { assertOwner(replacement, id: original[index].id, owner: index) }

        let sameHardware = "cg:12:34:noserial:Twin:2560x1440:external"
        let twins: [Screen] = [("1", sameHardware + ":position:0x0"), ("2", sameHardware + ":position:2560x0")]
        let moved: [Screen] = [("2", sameHardware + ":position:-2560x0"), ("1", sameHardware + ":position:0x0")]
        var identical = fixture(twins)
        identical.reconnect([moved[1]])
        check(identical.config.displayConfigs["1"] == nil, "one late twin cannot steal either folder")
        identical.reconnect(moved, settled: false)
        check(identical.config.displayConfigs["1"] == nil && identical.config.displayConfigs["2"] == nil, "unstable twins remain unbound")
        identical.reconnect(moved)
        assertOwner(identical, id: "2", owner: 0)
        assertOwner(identical, id: "1", owner: 1)
        check(WallpaperScreenIdentity.schedulerBindings(
            fingerprints: ["1": sameHardware, "2": sameHardware], screens: moved, allowRelativeRank: true
        ).isEmpty, "legacy identical records without positions must not be guessed by ID")
        check(WallpaperScreenIdentity.schedulerBindings(
            fingerprints: fixture(twins).fingerprints,
            screens: [("1", twins[0].fingerprint), ("2", twins[0].fingerprint)], allowRelativeRank: true
        ).isEmpty, "mirrored/duplicate positions remain ambiguous")

        var legacy = DisplaySchedulerConfig.fromLegacy(.default)
        legacy.folderIDs = ["offline-volume-folder"]
        let decoded = try JSONDecoder().decode(DisplaySchedulerConfig.self, from: JSONEncoder().encode(legacy))
        check(decoded.displayFingerprint == nil && decoded.folderIDs == legacy.folderIDs, "legacy config remains compatible")
        try checkServiceWiring()
        print("WAKE_DISPLAY_RELINK_REGRESSION_PASSED checks=\(checks) no_desktop_rendering=true")
    }

    private static func checkServiceWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent("Services/WallpaperSchedulerService.swift"), encoding: .utf8)
        check(!service.contains("syncDisplayFingerprints()"), "ordinary saves cannot overwrite physical ownership")
        check(!service.contains("Set(config.displayConfigs.keys).subtracting(currentScreenIDs)"), "relink cannot be restricted to vanished IDs")
        check(!service.contains("|| attempt >= 4"), "unstable topology never forces migration on timeout")
        check(service.contains("NSWorkspace.willSleepNotification") && service.contains("NSWorkspace.didWakeNotification"), "sleep and wake gate rotations")
        check(service.contains("guard canScheduleForCurrentScreens else { return false }"), "timed rotation waits for ownership")
        check(service.contains("self.screenChangeGeneration == generation else { return }"), "late unlock applies cannot commit old state")
        check(service.contains("currentScreenIDs.formUnion(config.displayConfigs.keys)"), "offline config retains rotation history")
        for name in ["lastChangedItemIDs", "lastChangeTimes", "usedItemIDs", "failedApplyRetryAfter", "onEndSwitchCooldownUntilByScreen"] {
            check(service.contains("\(name) = WallpaperScreenIdentity.relocatingSchedulerValues(\(name), using: relocations)"), "\(name) uses same atomic relocation")
        }
    }
}
