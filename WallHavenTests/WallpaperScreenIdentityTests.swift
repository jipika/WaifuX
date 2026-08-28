import XCTest
import CoreGraphics
@testable import WaifuX

final class WallpaperScreenIdentityTests: XCTestCase {
    func testNativePipelineRecoveryIsForcedAfterDisplayWake() {
        XCTAssertTrue(
            VideoWallpaperDisplayRecoveryPolicy.shouldRebuildNativePipeline(
                afterDisplayWake: true,
                displayConfigurationChanged: false,
                externalRenderingActive: false
            )
        )
    }

    func testNativePipelineRecoveryIsForcedWhenDisplayConfigurationChanges() {
        XCTAssertTrue(
            VideoWallpaperDisplayRecoveryPolicy.shouldRebuildNativePipeline(
                afterDisplayWake: false,
                displayConfigurationChanged: true,
                externalRenderingActive: false
            )
        )
    }

    func testExternalRendererDoesNotUseNativeRecoveryPolicy() {
        XCTAssertFalse(
            VideoWallpaperDisplayRecoveryPolicy.shouldRebuildNativePipeline(
                afterDisplayWake: true,
                displayConfigurationChanged: true,
                externalRenderingActive: true
            )
        )
    }

    func testFingerprintWithHardwareSerialIgnoresPosition() {
        let fp = WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: "cg:1:2:12345:external",
            hasHardwareSerial: true,
            position: CGPoint(x: 100, y: 0)
        )
        XCTAssertEqual(fp, "cg:1:2:12345:external")
    }

    func testFingerprintWithoutSerialIncludesPosition() {
        let left = WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: "cg:1:2:noserial:Dell:external",
            hasHardwareSerial: false,
            position: CGPoint(x: -1920, y: 0)
        )
        let right = WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: "cg:1:2:noserial:Dell:external",
            hasHardwareSerial: false,
            position: CGPoint(x: 1920, y: 0)
        )
        XCTAssertEqual(left, "cg:1:2:noserial:Dell:external:position:-1920x0")
        XCTAssertEqual(right, "cg:1:2:noserial:Dell:external:position:1920x0")
        XCTAssertNotEqual(left, right)
    }

    func testFingerprintPositionIsRounded() {
        let fp = WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: "legacy",
            hasHardwareSerial: false,
            position: CGPoint(x: 100.6, y: -0.4)
        )
        XCTAssertEqual(fp, "legacy:position:101x0")
    }
}
