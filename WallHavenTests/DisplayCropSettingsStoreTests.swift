import XCTest
@testable import WaifuX

final class DisplayCropSettingsStoreTests: XCTestCase {
    var store: DisplayCropSettingsStore!

    override func setUp() {
        super.setUp()
        // 用一个独立测试实例，避免污染单例 UserDefaults。
        store = DisplayCropSettingsStore(testDefaults: UserDefaults(suiteName: "crop-test-\(UUID().uuidString)")!)
    }

    func testDefaultSettingsIsAutoFill() {
        let s = store.settings(forScreenID: "nonexistent")
        XCTAssertEqual(s.aspectPreset, .autoFill)
        XCTAssertTrue(s.isEnabled)
        XCTAssertEqual(s.pan.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.pan.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.zoom, 1.0, accuracy: 1e-9)
    }

    func testUpdatePersistsForScreenID() {
        store.update(forScreenID: "screen-A") { $0.aspectPreset = .ratio21x9; $0.zoom = 2.0 }
        let s = store.settings(forScreenID: "screen-A")
        XCTAssertEqual(s.aspectPreset, .ratio21x9)
        XCTAssertEqual(s.zoom, 2.0, accuracy: 1e-9)
    }

    func testResetReturnsToAutoFill() {
        store.update(forScreenID: "screen-B") { $0.aspectPreset = .ratio16x9; $0.zoom = 3.0 }
        store.reset(forScreenID: "screen-B")
        let s = store.settings(forScreenID: "screen-B")
        XCTAssertEqual(s.aspectPreset, .autoFill)
        XCTAssertEqual(s.zoom, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.pan.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.pan.y, 0.5, accuracy: 1e-9)
    }

    func testClearRemovesEntry() {
        store.update(forScreenID: "screen-C") { $0.aspectPreset = .ratio4x3 }
        store.clear(forScreenID: "screen-C")
        let s = store.settings(forScreenID: "screen-C")
        XCTAssertEqual(s.aspectPreset, .autoFill)
    }

    func testReconstructFromSharedJSONRoundTrip() {
        store.update(forScreenID: "screen-D") { $0.aspectPreset = .custom; $0.customAspect = 2.5; $0.pan = CGPoint(x: 0.3, y: -0.2); $0.zoom = 1.5; $0.letterboxColorHex = "112233" }
        let shared = store.writeSharedCropPrefsForTesting()
        guard let restored = shared[42] else {
            XCTFail("expected displayID 42 in shared prefs")
            return
        }
        XCTAssertEqual(restored.aspectPreset, .custom)
        XCTAssertEqual(restored.customAspect ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(restored.zoom, 1.5, accuracy: 1e-9)
        XCTAssertEqual(restored.letterboxColorHex, "112233")
    }
}

// MARK: - reconciledCropState 重链/去腐（displayID 串台修复）

final class DisplayCropStateReconcilerTests: XCTestCase {

    private func snap(_ id: String, _ fp: String) -> DisplayCropStateReconciler.ScreenIdentitySnapshot {
        .init(screenID: id, fingerprint: fp)
    }

    private func settings(zoom: Double) -> DisplayCropSettings {
        var s = DisplayCropSettings.defaultSettings
        s.zoom = zoom
        return s
    }

    private let fpA = "cg:0x610:0x1234:serialA:external"
    private let fpB = "cg:0x1e6:0x5678:serialB:external"

    /// 重启后双屏 displayID 互换：设置应跟随物理显示器指纹，而不是 screenID。
    func testSwappedDisplayIDsKeepsSettingsWithTheirScreens() {
        let out = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: ["2": settings(zoom: 2.0), "3": settings(zoom: 3.0)],
            fingerprints: ["2": fpA, "3": fpB],
            currentScreens: [snap("3", fpA), snap("2", fpB)])
        XCTAssertEqual(out?.settings["3"]?.zoom ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertEqual(out?.settings["2"]?.zoom ?? -1, 3.0, accuracy: 1e-9)
    }

    /// displayID 被新屏回收复用：指纹不匹配 → 旧条目丢弃，回退默认。
    func testRecycledDisplayIDDropsStaleEntry() {
        let out = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: ["2": settings(zoom: 2.0)],
            fingerprints: ["2": fpA],
            currentScreens: [snap("2", fpB)])
        XCTAssertNil(out?.settings["2"])
    }

    /// 历史条目没记录过指纹（旧版 update(forScreenID:) 路径）→ 信任并补记。
    func testLegacyEntryWithoutFingerprintIsTrustedAndStamped() {
        let out = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: ["5": settings(zoom: 1.5)],
            fingerprints: [:],
            currentScreens: [snap("5", fpA)])
        XCTAssertEqual(out?.settings["5"]?.zoom ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(out?.fingerprints["5"], fpA)
    }

    /// 有真实变更时，离线孤儿条目保留（显示器暂时断开不丢配置）。
    func testOrphanEntryIsPreservedWhenOtherScreensChange() {
        let fpPos1 = "cg:0x610:0x1234:noserial:NAME:1920x1080:external:position:0x0"
        let fpPos2 = "cg:0x610:0x1234:noserial:NAME:1920x1080:external:position:1920x0"
        let out = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: ["1": settings(zoom: 1.0), "9": settings(zoom: 4.0)],
            fingerprints: ["1": fpPos1, "9": fpB],
            currentScreens: [snap("1", fpPos2)])
        XCTAssertEqual(out?.settings["9"]?.zoom ?? -1, 4.0, accuracy: 1e-9)
    }

    /// 无序列号显示器仅桌面位置变化 → 按稳定部分匹配，设置保留、指纹更新。
    func testPositionOnlyChangeMatchesAndRestampsFingerprint() {
        let fpPos1 = "cg:0x610:0x1234:noserial:NAME:1920x1080:external:position:0x0"
        let fpPos2 = "cg:0x610:0x1234:noserial:NAME:1920x1080:external:position:1920x0"
        XCTAssertTrue(DisplayCropStateReconciler.isFingerprintMatch(fpPos1, fpPos2))
        let out = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: ["2": settings(zoom: 2.5)],
            fingerprints: ["2": fpPos1],
            currentScreens: [snap("2", fpPos2)])
        XCTAssertEqual(out?.settings["2"]?.zoom ?? -1, 2.5, accuracy: 1e-9)
        XCTAssertEqual(out?.fingerprints["2"], fpPos2)
    }

    /// 同 ID 但型号不同的回收条目：指纹稳定部分不匹配 → 丢弃。
    func testRecycledEntryFromDifferentModelIsDropped() {
        let fpPos1 = "cg:0x610:0x1234:noserial:NAME:1920x1080:external:position:0x0"
        let fpOther = "cg:0x1e6:0x9999:noserial:OTHER:1920x1080:external:position:1920x0"
        XCTAssertFalse(DisplayCropStateReconciler.isFingerprintMatch(fpPos1, fpOther))
        let out = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: ["2": settings(zoom: 2.5)],
            fingerprints: ["2": fpPos1],
            currentScreens: [snap("2", fpOther)])
        XCTAssertNil(out?.settings["2"])
    }

    /// 无变化 → nil（不触发无意义持久化）；空屏列表 → nil（不误改状态）。
    func testNoChangeAndEmptyScreensReturnNil() {
        let out = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: ["2": settings(zoom: 2.0)],
            fingerprints: ["2": fpA],
            currentScreens: [snap("2", fpA)])
        XCTAssertNil(out)
        let outEmpty = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: ["2": settings(zoom: 2.0)],
            fingerprints: ["2": fpA],
            currentScreens: [])
        XCTAssertNil(outEmpty)
    }
}
