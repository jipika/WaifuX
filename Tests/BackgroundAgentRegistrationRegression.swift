import Foundation
import ServiceManagement

@MainActor
private final class TestService: BackgroundAgentServiceRegistration {
    var status: SMAppService.Status
    var registrations = 0
    var unregistrations = 0
    var result: SMAppService.Status = .enabled
    var failure: Error?
    init(_ status: SMAppService.Status) { self.status = status }
    func register() throws {
        registrations += 1
        status = result
        if let failure { throw failure }
    }
    func unregister() async throws {
        unregistrations += 1
        status = .notRegistered
    }
}

@main
private enum RegistrationRegression {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
            print("PASS \(name)")
        }
        func registrationError(_ service: TestService) -> BackgroundAgentRegistrationError? {
            do { try BackgroundAgentRegistration.ensureEnabled(service); return nil }
            catch { return error as? BackgroundAgentRegistrationError }
        }
        for status in [SMAppService.Status.notFound, .notRegistered] {
            let service = TestService(status)
            try BackgroundAgentRegistration.ensureEnabled(service)
            check(service.registrations == 1 && service.status == .enabled, "fresh \(status.rawValue) registers")
            try BackgroundAgentRegistration.ensureEnabled(service)
            check(service.registrations == 1, "repeated startup preserves running service \(status.rawValue)")
        }
        let enabled = TestService(.enabled)
        try BackgroundAgentRegistration.ensureEnabled(enabled)
        check(enabled.registrations == 0, "enabled service is not registered again")
        // BTM 说 enabled、launchd 域里却没有 job 的脱节状态：只能注销再注册恢复。
        let repair = TestService(.enabled)
        try await BackgroundAgentRegistration.repairLaunchdRegistration(repair)
        check(repair.unregistrations == 1 && repair.registrations == 1 && repair.status == .enabled,
              "service missing from launchd is repaired by re-registering")
        let repairDenied = TestService(.enabled)
        repairDenied.result = .requiresApproval
        do {
            try await BackgroundAgentRegistration.repairLaunchdRegistration(repairDenied)
            preconditionFailure("expected approval error")
        } catch {
            if case .approvalRequired? = error as? BackgroundAgentRegistrationError {
                check(repairDenied.unregistrations == 1, "repair surfaces the approval prompt when registration is denied")
            } else { preconditionFailure("approval error") }
        }
        let disabled = TestService(.requiresApproval)
        if case .approvalRequired? = registrationError(disabled) {
            check(disabled.registrations == 0, "user-disabled service requires approval without reregistering")
        } else { preconditionFailure("approval error") }
        let awaitingApproval = TestService(.notFound)
        awaitingApproval.result = .requiresApproval
        if case .approvalRequired? = registrationError(awaitingApproval) {
            check(awaitingApproval.registrations == 1, "registration awaiting approval is classified")
        } else { preconditionFailure("approval error") }
        awaitingApproval.status = .notRegistered
        awaitingApproval.failure = NSError(domain: "com.apple.ServiceManagement", code: 1)
        if case .approvalRequired? = registrationError(awaitingApproval) {
            check(awaitingApproval.registrations == 2, "launch denied reports approval requirement")
        } else { preconditionFailure("approval error") }
        let missing = TestService(.notFound)
        missing.result = .notFound
        if case .unavailable(3)? = registrationError(missing) {
            check(missing.registrations == 1, "persistent notFound is a registration error, not an approval prompt")
        } else { preconditionFailure("unavailable error") }
        let failed = TestService(.notRegistered)
        failed.result = .notRegistered
        failed.failure = NSError(domain: "test.registration", code: 42)
        do { try BackgroundAgentRegistration.ensureEnabled(failed); preconditionFailure("expected failure") }
        catch {
            let error = error as NSError
            check(error.domain == "test.registration" && error.code == 42, "registration preserves the underlying failure")
        }

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("waifux-registration-\(UUID().uuidString).app")
        defer { try? manager.removeItem(at: root) }
        let plist = root.appendingPathComponent("Contents/Library/LaunchAgents/\(BackgroundAgentWire.plistName)")
        let program = "Contents/Helpers/WaifuXHelper.app/Contents/MacOS/WaifuXHelper"
        let executable = root.appendingPathComponent(program)
        try manager.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        func save(_ program: String, _ services: [String: Bool] = [BackgroundAgentWire.machServiceName: true]) throws {
            try PropertyListSerialization.data(fromPropertyList: ["BundleProgram": program, "MachServices": services], format: .xml, options: 0).write(to: plist)
        }
        func invalidBundle(_ name: String) {
            do { try BackgroundAgentRegistration.validateBundle(root); preconditionFailure(name) }
            catch { check(error is BackgroundAgentRegistrationError, name) }
        }
        invalidBundle("missing plist is an installation error")
        try save(program)
        invalidBundle("missing executable is an installation error")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        invalidBundle("nonexecutable Helper is rejected")
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try BackgroundAgentRegistration.validateBundle(root)
        check(true, "valid embedded components permit registration")
        try save(program, [:])
        invalidBundle("missing Mach service is rejected")
        try save("/bin/sh")
        invalidBundle("absolute BundleProgram is rejected")
        try save("../../bin/sh")
        invalidBundle("BundleProgram escaping the host is rejected")
        try manager.removeItem(at: executable)
        try manager.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        try save(program)
        invalidBundle("executable symlink escaping the host is rejected")
        print("HELPER_REGISTRATION_POLICY_PASSED checks=\(count)")
    }
}
