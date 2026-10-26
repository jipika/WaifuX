import AppKit
import Foundation

/// Executes the production resolvers with synthetic topologies, without
/// requiring physical hotplug or mutating the system display configuration.
@main enum HelperDisplayControlSimulation {
    static var failed = 0
    static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failed += 1 }
    }
    static func main() {
        let serials = [(id: "1", fingerprint: "serial-A"), (id: "2", fingerprint: "serial-B")]
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: "serial-A", screens: serials) == 0, "Helper resolves unchanged target")
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: "serial-A", screens: serials.reversed()) == 1, "Helper ignores topology ordering")
        let reused = [(id: "1", fingerprint: "serial-B"), (id: "3", fingerprint: "serial-A")]
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: "serial-A", screens: reused) == 1, "Helper follows physical identity after ID reuse")
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: "serial-A", screens: [reused[0]]) == nil, "Helper rejects unplugged physical target")
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: "serial-A", screens: []) == nil, "Helper rejects empty topology")
        let identical = [(id: "1", fingerprint: "noserial:position:0x0"), (id: "2", fingerprint: "noserial:position:1920x0")]
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: identical[0].fingerprint, screens: identical) == 0, "Helper accepts fresh identity among identical monitors")
        let moved = [(id: "1", fingerprint: "noserial:position:-1920x0"), (id: "3", fingerprint: "noserial:position:0x0")]
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: identical[0].fingerprint, screens: moved) == nil, "Helper rejects stale position when matching hardware is ambiguous")
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "old", fingerprint: identical[0].fingerprint, screens: moved) == nil, "Helper rejects ambiguous fingerprint fallback")
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "old", fingerprint: identical[0].fingerprint, screens: [moved[0]]) == 0, "Helper recovers unique moved no-serial monitor")
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: "serial-A", screens: [serials[0], serials[0]]) == nil, "Helper rejects duplicate target identities")

        // 2026-10-26 x86 用户日志实锤：同一块无序列号内建屏，主 App（zh）记下
        // 中文名指纹，Helper（en）枚举出英文名指纹。比较层必须剥掉本地化屏幕名。
        let zhBuiltin = "cg:1552:41028:noserial:内建视网膜显示器:3584x2240:builtin:position:0x0"
        let enBuiltin = "cg:1552:41028:noserial:Built-in Retina Display:3584x2240:builtin:position:0x0"
        check(WallpaperScreenIdentity.nameTolerantPart(zhBuiltin) == WallpaperScreenIdentity.nameTolerantPart(enBuiltin), "name-tolerant part erases localized screen name")
        check(zhBuiltin != enBuiltin, "sanity: raw fingerprints really differ by name")
        check(WallpaperScreenIdentity.fingerprintsMatch(zhBuiltin, enBuiltin), "fingerprints match across zh/en names")
        check(!WallpaperScreenIdentity.fingerprintsMatch("cg:1:2:3:4:5", "cg:1:2:9:4:5"), "serial-numbered fingerprints never erase fields")
        check(WallpaperScreenIdentity.nameTolerantPart("fallback:内建视网膜显示器") == "fallback:内建视网膜显示器", "fallback fingerprints are untouched")
        check(
            WallpaperScreenIdentity.commandTargetIndex(identifier: nil, fingerprint: zhBuiltin, screens: [(id: "69734662", fingerprint: enBuiltin)]) == 0,
            "Helper recovers rebuilt-in display across localized names after ID change"
        )
        let zhPair = [
            (id: "1", fingerprint: "cg:1552:41028:noserial:内建视网膜显示器:3584x2240:builtin:position:0x0"),
            (id: "2", fingerprint: "cg:1552:41028:noserial:内建视网膜显示器:3584x2240:builtin:position:1920x0")
        ]
        let enPair = [
            (id: "1", fingerprint: "cg:1552:41028:noserial:Built-in Retina Display:3584x2240:builtin:position:0x0"),
            (id: "2", fingerprint: "cg:1552:41028:noserial:Built-in Retina Display:3584x2240:builtin:position:1920x0")
        ]
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: "1", fingerprint: zhPair[0].fingerprint, screens: enPair) == 0, "identical monitors stay position-pinned across localized names")
        check(WallpaperScreenIdentity.commandTargetIndex(identifier: nil, fingerprint: zhPair[0].fingerprint, screens: enPair) == nil, "ambiguous no-position fallback still rejected across localized names")
        check(
            WallpaperScreenIdentity.schedulerHardwareKey(zhBuiltin) == WallpaperScreenIdentity.schedulerHardwareKey(enBuiltin),
            "scheduler hardware grouping ignores localized screen names"
        )
        check(
            WallpaperScreenIdentity.schedulerBindings(
                fingerprints: ["old": zhBuiltin],
                screens: [(id: "69734662", fingerprint: enBuiltin)],
                allowRelativeRank: true
            ) == ["old": "69734662"],
            "scheduler relinks built-in display across localized names"
        )

        typealias Screen = VideoRendererScreenRouting.Screen
        let old = [Screen(identifier: "1", fingerprint: "serial-A"), Screen(identifier: "2", fingerprint: "serial-B")]
        let current = [Screen(identifier: "1", fingerprint: "serial-B"), Screen(identifier: "3", fingerprint: "serial-A")]
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: old, previousScreens: old) == 0, "renderer resolves unchanged owned target")
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: current, previousScreens: old) == 1, "renderer follows owned physical display after ID reuse")
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: [current[0]], previousScreens: old) == nil, "renderer rejects reused ID when owned display was unplugged")
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: [], previousScreens: old) == nil, "renderer rejects empty topology")
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "3", screens: current) == 1, "renderer accepts new target without history")
        let duplicate = [Screen(identifier: "3", fingerprint: "serial-A"), Screen(identifier: "4", fingerprint: "serial-A")]
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: duplicate, previousScreens: old) == nil, "renderer rejects ambiguous physical recovery")
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: current, previousScreens: old, expectedFingerprint: "serial-B") == 0, "fresh renderer set can intentionally target the new owner of a reused ID")
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: current, previousScreens: old, expectedFingerprint: "serial-A") == 1, "captured renderer target survives topology changing after command encoding")
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: [current[0]], expectedFingerprint: "serial-A") == nil, "captured target never falls back to reused ID without history")
        let noSerialOld = [Screen(identifier: "1", fingerprint: "noserial:position:0x0")]
        let noSerialNew = [Screen(identifier: "3", fingerprint: "noserial:position:-1920x0")]
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: noSerialNew, previousScreens: noSerialOld) == 0, "renderer recovers unique physical target after desktop position changes")
        let noSerialAmbiguous = noSerialNew + [Screen(identifier: "1", fingerprint: "noserial:position:1920x0")]
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "1", screens: noSerialAmbiguous, previousScreens: noSerialOld) == nil, "renderer rejects ambiguous no-serial target even with reused ID")
        let zhNamedOld = [Screen(identifier: "2077748985", fingerprint: zhBuiltin)]
        check(VideoRendererScreenRouting.resolvedIndex(stableID: "2077748985", screens: [(identifier: "69734662", fingerprint: enBuiltin)].map { Screen(identifier: $0.identifier, fingerprint: $0.fingerprint) }, previousScreens: zhNamedOld) == 0, "renderer recovers owned display across localized names after reboot ID change")

        let ranks = WallpaperScreenIdentity.pairByRelativeRank(
            orphans: [("left", CGPoint(x: 0, y: 0)), ("right", CGPoint(x: 1920, y: 0))],
            screens: [("new-right", CGPoint(x: 0, y: 0)), ("new-left", CGPoint(x: -1920, y: 0))]
        )
        check(ranks["left"] == "new-left" && ranks["right"] == "new-right", "relative rank survives main display origin translation")
        let vertical = WallpaperScreenIdentity.pairByRelativeRank(
            orphans: [("top", CGPoint(x: 0, y: 1080)), ("bottom", CGPoint(x: 0, y: 0))],
            screens: [("new-bottom", CGPoint(x: 0, y: -1080)), ("new-top", CGPoint(x: 0, y: 0))]
        )
        check(vertical["top"] == "new-top" && vertical["bottom"] == "new-bottom", "relative rank preserves vertical monitor ownership")
        if failed > 0 { exit(1) }
        print("HELPER_DISPLAY_CONTROL_SIMULATION_PASSED")
    }
}
