import Darwin

/// A snapshot of this process's descendants, including process birth identity.
/// Captured before graceful shutdown so already reparented workers can still be
/// cleaned up without matching a reused PID or an unrelated user's process.
enum BackgroundChildProcessCleanup {
    struct Child: Sendable {
        let pid: Int32
        let uid: UInt32
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
        var executableName: String = ""
    }

    static func snapshot(rootPID: Int32 = getpid()) -> [Child] {
        guard rootPID > 1 else { return [] }
        var visited = Set<Int32>([rootPID])
        func descendants(_ parent: Int32, depth: Int) -> [Child] {
            guard depth < 32 else { return [] }
            let capacity = min(8192, max(64, Int(proc_listchildpids(parent, nil, 0)) + 32))
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return [] }
            var result: [Child] = []
            for pid in pids.prefix(min(Int(count), capacity)) where pid > 1 {
                guard visited.insert(pid).inserted, let info = information(pid),
                      info.pbi_ppid == UInt32(parent), info.pbi_uid == getuid() else { continue }
                result += descendants(pid, depth: depth + 1)
                let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                result.append(Child(pid: pid, uid: info.pbi_uid,
                                    startedSeconds: info.pbi_start_tvsec,
                                    startedMicroseconds: info.pbi_start_tvusec, executableName: name))
            }
            return result
        }
        return descendants(rootPID, depth: 0)
    }

    @discardableResult
    static func terminate(_ children: [Child]) -> [Int32] {
        var terminated: [Int32] = []
        for child in children {
            guard child.pid > 1, child.pid != getpid(), let info = information(child.pid),
                  info.pbi_uid == child.uid,
                  info.pbi_start_tvsec == child.startedSeconds,
                  info.pbi_start_tvusec == child.startedMicroseconds else { continue }
            // This is the final fallback after service-specific graceful stop.
            // SIGKILL also ends suspended workers; no delayed timer must outlive
            // the process that owns it.
            if kill(child.pid, SIGKILL) == 0 { terminated.append(child.pid) }
        }
        return terminated
    }

    private static func information(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
