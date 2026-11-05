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

// MARK: - Helper 单实例锁的持有者

/// 按「谁打开着 Helper 单实例锁文件」识别 Helper 进程。
///
/// 用户把新包拖进 /Applications 替换旧包时，旧 Helper 可能还活着并占着
/// `background-helper.lock`：它的可执行文件已被替换/移进废纸篓，路径前缀
/// 匹配不到当前 bundle；新 Helper 拿不到锁直接 `exit(0)`。所以这里不按路径，
/// 而按「同 uid + 进程名 WaifuXHelper + 打开着同一个 inode 的锁文件」三条件识别，
/// 绝不只按进程名杀进程。测试 Helper 用 `.test` 锁文件，天然不会命中生产锁。
extension BackgroundChildProcessCleanup {
    struct HelperProcess: Sendable {
        let child: Child
        let path: String
        let holdsLock: Bool
    }

    static let helperExecutableName = "WaifuXHelper"

    /// 同 uid 的全部 WaifuXHelper 进程（不含自己），并标出是否打开着 `lockPath`。
    static func helperProcesses(lockPath: String) -> [HelperProcess] {
        var lockStat = stat()
        let lockIdentity: (dev: UInt32, ino: UInt64)? = stat(lockPath, &lockStat) == 0
            ? (UInt32(bitPattern: lockStat.st_dev), UInt64(lockStat.st_ino)) : nil
        let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [Int32](repeating: 0, count: capacity)
        let byteCount = Int32(capacity * MemoryLayout<Int32>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, byteCount) }
        guard count > 0 else { return [] }
        var result: [HelperProcess] = []
        for pid in pids.prefix(min(Int(count), capacity)) where pid > 1 && pid != getpid() {
            guard let info = information(pid), info.pbi_uid == getuid(),
                  processName(info) == helperExecutableName else { continue }
            let holds = lockIdentity.map { holdsFile(pid: pid, dev: $0.dev, ino: $0.ino) } ?? false
            result.append(HelperProcess(
                child: Child(pid: pid, uid: info.pbi_uid,
                             startedSeconds: info.pbi_start_tvsec,
                             startedMicroseconds: info.pbi_start_tvusec,
                             executableName: helperExecutableName),
                path: executablePath(pid),
                holdsLock: holds))
        }
        return result
    }

    /// 结束仍占着 `lockPath` 的 Helper 及其子进程（渲染器 / web daemon）。
    ///
    /// 先 SIGTERM 给渲染器留出释放桌面窗口与音频的窗口，3s 后对仍存活且身份
    /// （pid + 启动时间）未变的进程 SIGKILL。返回被处理的持有者与最终仍存活的 pid。
    static func terminateHelperLockHolders(lockPath: String) async -> (holders: [HelperProcess], survivors: [Int32]) {
        let holders = helperProcesses(lockPath: lockPath).filter(\.holdsLock)
        guard !holders.isEmpty else { return ([], []) }
        var targets: [Child] = []
        for holder in holders {
            targets += snapshot(rootPID: holder.child.pid)
            targets.append(holder.child)
        }
        for target in targets where sameProcess(target) { kill(target.pid, SIGTERM) }
        for _ in 0..<30 where targets.contains(where: sameProcess) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        terminate(targets.filter(sameProcess))
        for _ in 0..<20 where targets.contains(where: sameProcess) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return (holders, holders.map(\.child).filter(sameProcess).map(\.pid))
    }

    /// pid 仍指向当初那个进程（防 pid 复用）且不是僵尸。
    private static func sameProcess(_ child: Child) -> Bool {
        guard let info = information(child.pid) else { return false }
        return info.pbi_uid == child.uid
            && info.pbi_start_tvsec == child.startedSeconds
            && info.pbi_start_tvusec == child.startedMicroseconds
            && info.pbi_status != UInt32(SZOMB)
    }

    private static func processName(_ info: proc_bsdinfo) -> String {
        var name = info.pbi_name
        let fromName = withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !fromName.isEmpty { return fromName }
        var comm = info.pbi_comm
        return withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func executablePath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 该进程是否打开着 (dev, ino) 指向的文件。同 uid 进程无需 root（与 lsof 同权限）。
    private static func holdsFile(pid: Int32, dev: UInt32, ino: UInt64) -> Bool {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let bytes = Int32(fds.count * stride)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bytes) }
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            let stat = vnode.pvip.vip_vi.vi_stat
            if stat.vst_dev == dev && stat.vst_ino == ino { return true }
        }
        return false
    }
}
