import AppKit
import Foundation
import Security
import Darwin

/// Pure targeting rules. A user selection on a different/historical Space is not evidence.
enum WallpaperAgentRecoveryTargetPolicy {
    static let bundleID = "com.apple.wallpaper.agent"
    static let executable = "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
    static let provider = "com.waifux.app.wallpaperextension"

    struct Scope: Equatable, Sendable {
        let displayID: UInt32
        let displayUUID: String
        let spaceUUID: String
    }

    static func isSelected(root: [String: Any], scope: Scope) -> Bool {
        guard scope.displayID > 0, UUID(uuidString: scope.displayUUID) != nil,
              scope.spaceUUID.isEmpty || UUID(uuidString: scope.spaceUUID) != nil else { return false }
        if let unified = root["AllSpacesAndDisplays"], !(unified is NSNull), unified as? String != "$null" {
            guard let value = unified as? [String: Any], let desktop = value["Desktop"] as? [String: Any] else { return false }
            return isOurDesktop(desktop)
        }
        var selected: [String: Any]?
        var selectedDate: Date?
        if let value = root["Displays"] {
            guard let displays = value as? [String: Any] else { return false }
            if let value = displays.first(where: { $0.key.caseInsensitiveCompare(scope.displayUUID) == .orderedSame })?.value {
                guard let display = value as? [String: Any], let desktop = display["Desktop"] as? [String: Any],
                      let date = desktop["LastSet"] as? Date, date.timeIntervalSince1970.isFinite else { return false }
                selected = desktop; selectedDate = date
            }
        }
        if let value = root["Spaces"] {
            guard let spaces = value as? [String: Any] else { return false }
            // The native current-Space constructor uses an empty UUID on the first Space.
            if let value = spaces.first(where: { $0.key.caseInsensitiveCompare(scope.spaceUUID) == .orderedSame })?.value {
                guard let space = value as? [String: Any] else { return false }
                var displayValue: Any?
                if let value = space["Displays"] {
                    guard let displays = value as? [String: Any] else { return false }
                    displayValue = displays.first(where: { $0.key.caseInsensitiveCompare(scope.displayUUID) == .orderedSame })?.value
                }
                if displayValue == nil { displayValue = space["Default"] }
                if let value = displayValue {
                    guard let display = value as? [String: Any], let desktop = display["Desktop"] as? [String: Any],
                          let date = desktop["LastSet"] as? Date, date.timeIntervalSince1970.isFinite else { return false }
                    if selectedDate == nil || date >= selectedDate! { selected = desktop }
                }
            }
        }
        return selected.map(isOurDesktop) ?? false
    }

    static func targetIsAllowed(pid: Int32, ownPID: Int32, owner: UInt32, user: UInt32,
                                path: String, signatureValid: Bool, startSeconds: UInt64) -> Bool {
        pid > 1 && pid != ownPID && owner == user && user != 0
            && path == executable && signatureValid && startSeconds > 0
    }

    private static func isOurDesktop(_ desktop: [String: Any]) -> Bool {
        guard let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["Provider"] as? String == provider else { return false }
        if let shuffle = content["Shuffle"], !(shuffle is NSNull), shuffle as? String != "$null" { return false }
        return true
    }
}

/// Narrow, explicitly user-approved exception to the normal no-Agent-restart rule.
/// Never registers an extension, edits the wallpaper store or sends a broad name-based signal.
@MainActor
enum WallpaperAgentRecoveryExecutor {
    private static let skyLightLibrary = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private struct Target: Equatable {
        let pid: Int32
        let owner: UInt32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let path: String
    }

    static func currentScope(displayID: UInt32) -> WallpaperAgentRecoveryTargetPolicy.Scope? {
        guard let library = skyLightLibrary,
              let uuidAddress = dlsym(library, "CGDisplayCreateUUIDFromDisplayID"),
              let mainAddress = dlsym(library, "CGSMainConnectionID"),
              let spacesAddress = dlsym(library, "CGSCopyManagedDisplaySpaces") else { return nil }
        let makeUUID = unsafeBitCast(uuidAddress, to: (@convention(c) (UInt32) -> UnsafeRawPointer?).self)
        guard let pointer = makeUUID(displayID) else { return nil }
        let uuid = Unmanaged<CFUUID>.fromOpaque(pointer).takeRetainedValue()
        let uuidString = CFUUIDCreateString(nil, uuid) as String
        let main = unsafeBitCast(mainAddress, to: (@convention(c) () -> UInt32).self)
        let spaces = unsafeBitCast(spacesAddress, to: (@convention(c) (UInt32) -> UnsafeRawPointer?).self)
        guard let pointer = spaces(main()),
              let rows = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? [[String: Any]],
              let row = rows.first(where: { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuidString) == .orderedSame }),
              let current = row["Current Space"] as? [String: Any],
              (current["type"] as? NSNumber)?.intValue == 0,
              let space = current["uuid"] as? String else { return nil }
        return .init(displayID: displayID, displayUUID: uuidString, spaceUUID: space)
    }

    static func isSelected(_ scope: WallpaperAgentRecoveryTargetPolicy.Scope) -> Bool {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let size = try? store.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: store),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return WallpaperAgentRecoveryTargetPolicy.isSelected(root: root, scope: scope)
    }

    /// SIGTERM targets one revalidated Apple executable owned by this login user.
    /// launchd recreates its runtime; the caller must still verify fresh rendering.
    static func restartCurrentUserAgent(shouldContinue: () -> Bool) -> Bool {
        guard shouldContinue(), sessionAllowsRecovery(), getuid() == geteuid(),
              let target = currentTarget(), appleSignatureIsValid(),
              shouldContinue(), sessionAllowsRecovery(), currentTarget() == target else { return false }
        return Darwin.kill(target.pid, SIGTERM) == 0
    }

    static func currentAgentPID() -> Int32? { currentTarget()?.pid }

    static func sessionAllowsRecovery() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == geteuid(),
              (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true,
              (session["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue == true else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true
    }

    private static func currentTarget() -> Target? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: WallpaperAgentRecoveryTargetPolicy.bundleID)
            .filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first,
              app.executableURL?.standardizedFileURL.path == WallpaperAgentRecoveryTargetPolicy.executable else { return nil }
        let pid = app.processIdentifier
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0, Int(length) < buffer.count else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard WallpaperAgentRecoveryTargetPolicy.targetIsAllowed(pid: pid, ownPID: getpid(), owner: info.pbi_uid,
            user: geteuid(), path: path, signatureValid: true, startSeconds: info.pbi_start_tvsec) else { return nil }
        return Target(pid: pid, owner: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                      startMicroseconds: info.pbi_start_tvusec, path: path)
    }

    private static func appleSignatureIsValid() -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let url = URL(fileURLWithPath: WallpaperAgentRecoveryTargetPolicy.executable)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
