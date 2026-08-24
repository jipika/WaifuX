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
