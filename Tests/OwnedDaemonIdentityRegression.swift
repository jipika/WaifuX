import Darwin
import Foundation

@main
enum OwnedDaemonIdentityRegression {
    static func main() throws {
        if CommandLine.arguments.count > 1, ["daemon", "client"].contains(CommandLine.arguments[1]) {
            while true { usleep(100_000) }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let pidFile = root.appendingPathComponent("daemon.pid")
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["60"]
        try unrelated.run()
        let client = Process()
        client.executableURL = executable
        client.arguments = ["client"]
        try client.run()
        let daemon = Process()
        daemon.executableURL = executable
        daemon.arguments = ["daemon"]
        try daemon.run()
        defer {
            for process in [unrelated, client, daemon] where process.isRunning {
                process.terminate()
                Darwin.kill(process.processIdentifier, SIGCONT)
                process.waitUntilExit()
            }
        }
        Thread.sleep(forTimeInterval: 0.15)
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "DaemonIdentityRegression", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
            print("PASS \(message)")
        }
        func writePID(_ pid: Int32) throws {
            try String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
        }
        try writePID(unrelated.processIdentifier)
        try check(OwnedDaemonPIDFile.identity(at: pidFile, expectedExecutables: [executable]) == nil
                    && unrelated.isRunning, "stale daemon PID file cannot target an unrelated real sleep process")
        try writePID(client.processIdentifier)
        try check(OwnedDaemonPIDFile.identity(at: pidFile, expectedExecutables: [executable]) == nil
                    && client.isRunning, "same executable in client mode cannot be mistaken for a daemon")
        try writePID(daemon.processIdentifier)
        guard let identity = OwnedDaemonPIDFile.identity(at: pidFile, expectedExecutables: [executable]) else {
            throw NSError(domain: "DaemonIdentityRegression", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "real daemon identity was not recognized"])
        }
        try check(identity.stillMatches(), "numeric PID file recognizes the expected executable in daemon mode")
        let wrongBirth = OwnedProcessIdentity(pid: identity.pid, uid: identity.uid,
            startedSeconds: identity.startedSeconds + 1, startedMicroseconds: identity.startedMicroseconds,
            executablePath: identity.executablePath, requiredFirstArgument: "daemon")
        try check(!wrongBirth.signal(SIGKILL) && daemon.isRunning, "changed process birth identity refuses SIGKILL")
        let wrongUser = OwnedProcessIdentity(pid: identity.pid, uid: identity.uid + 1,
            startedSeconds: identity.startedSeconds, startedMicroseconds: identity.startedMicroseconds,
            executablePath: identity.executablePath, requiredFirstArgument: "daemon")
        try check(!wrongUser.signal(SIGKILL) && daemon.isRunning, "changed process owner refuses SIGKILL")
        let wrongExecutable = OwnedProcessIdentity(pid: identity.pid, uid: identity.uid,
            startedSeconds: identity.startedSeconds, startedMicroseconds: identity.startedMicroseconds,
            executablePath: "/bin/sleep", requiredFirstArgument: "daemon")
        try check(!wrongExecutable.signal(SIGKILL) && daemon.isRunning, "changed executable identity refuses SIGKILL")
        let symlink = root.appendingPathComponent("daemon-executable-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)
        try check(OwnedDaemonPIDFile.identity(at: pidFile, expectedExecutables: [symlink]) != nil,
                  "executable symlinks resolve to the same real daemon identity")
        try writePID(client.processIdentifier)
        OwnedDaemonPIDFile.remove(at: pidFile, ifPIDMatches: daemon.processIdentifier)
        try check(OwnedDaemonPIDFile.readPID(at: pidFile) == client.processIdentifier,
                  "cleanup preserves a PID file already replaced by another process")
        try writePID(daemon.processIdentifier)
        try check(identity.signal(SIGSTOP), "verified daemon can be suspended in isolation")
        try check(identity.signal(SIGKILL), "identity guarded SIGKILL ends a suspended daemon")
        daemon.waitUntilExit()
        try check(!identity.stillMatches() && !identity.signal(SIGKILL),
                  "an exited daemon identity cannot be signalled again")
        OwnedDaemonPIDFile.remove(at: pidFile, ifPIDMatches: daemon.processIdentifier)
        try check(!FileManager.default.fileExists(atPath: pidFile.path), "matching stale numeric PID file is removed")
        try check(unrelated.isRunning && client.isRunning, "unrelated process and same executable client both survive final cleanup")
        print("OWNED_DAEMON_IDENTITY_REGRESSION_PASSED")
    }
}
