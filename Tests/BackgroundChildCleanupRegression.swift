import Foundation
import Darwin

@main
enum BackgroundChildCleanupRegression {
    static func main() throws {
        let unrelated = Int32(CommandLine.arguments[1])!
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "ChildCleanupRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            count += 1
            print("PASS \(message)")
        }
        defer { BackgroundChildProcessCleanup.terminate(BackgroundChildProcessCleanup.snapshot()) }
        let ordinary = Process()
        ordinary.executableURL = URL(fileURLWithPath: "/bin/sleep")
        ordinary.arguments = ["60"]
        try ordinary.run()
        let first = BackgroundChildProcessCleanup.snapshot()
        try check(first.contains { $0.pid == ordinary.processIdentifier }, "snapshot contains this process's real worker")
        let identity = first.first { $0.pid == ordinary.processIdentifier }!
        let reused = BackgroundChildProcessCleanup.Child(pid: identity.pid, uid: identity.uid,
            startedSeconds: identity.startedSeconds + 1, startedMicroseconds: identity.startedMicroseconds)
        try check(BackgroundChildProcessCleanup.terminate([reused]).isEmpty && ordinary.isRunning, "changed process birth identity is not signalled")
        let wrongUser = BackgroundChildProcessCleanup.Child(pid: identity.pid, uid: identity.uid + 1,
            startedSeconds: identity.startedSeconds, startedMicroseconds: identity.startedMicroseconds)
        try check(BackgroundChildProcessCleanup.terminate([wrongUser]).isEmpty && ordinary.isRunning, "changed process owner is not signalled")
        let nested = Process()
        nested.executableURL = URL(fileURLWithPath: "/bin/sh")
        nested.arguments = ["-c", "sleep 60 & wait"]
        try nested.run()
        Thread.sleep(forTimeInterval: 0.2)
        kill(nested.processIdentifier, SIGSTOP)
        let children = BackgroundChildProcessCleanup.snapshot()
        try check(children.count >= 3, "snapshot includes a suspended parent and its child")
        try check(!children.contains { $0.pid == unrelated }, "unrelated sibling is excluded from the descendant graph")
        let signals = BackgroundChildProcessCleanup.terminate(children)
        ordinary.waitUntilExit()
        nested.waitUntilExit()
        try check(signals.contains(ordinary.processIdentifier) && signals.contains(nested.processIdentifier), "final cleanup ends ordinary and suspended workers")
        for _ in 0..<30 {
            if children.allSatisfy({ kill($0.pid, 0) != 0 }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try check(children.allSatisfy { kill($0.pid, 0) != 0 }, "nested workers do not remain after their parent exits")
        try check(kill(unrelated, 0) == 0, "unrelated sibling remains alive after cleanup")
        print("BACKGROUND_CHILD_CLEANUP_REGRESSION_PASSED checks=\(count)")
    }
}
