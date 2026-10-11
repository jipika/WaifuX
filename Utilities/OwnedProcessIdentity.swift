import Darwin
import Foundation

/// A PID is only a lookup key. Keep its owner, birth time and executable before
/// signalling so a stale PID file or a delayed watchdog cannot kill a new process.
struct OwnedProcessIdentity: Sendable {
    let pid: Int32
    let uid: UInt32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let executablePath: String
    var requiredFirstArgument: String? = nil

    static func capture(_ pid: Int32) -> OwnedProcessIdentity? {
        guard pid > 1, pid != getpid(), let info = information(pid),
              info.pbi_uid == getuid(), let path = executablePath(pid) else { return nil }
        return OwnedProcessIdentity(pid: pid, uid: info.pbi_uid,
                                    startedSeconds: info.pbi_start_tvsec,
                                    startedMicroseconds: info.pbi_start_tvusec,
                                    executablePath: path)
    }

    static func capture(_ pid: Int32, expectedExecutables: [URL],
                        requiredFirstArgument: String? = nil) -> OwnedProcessIdentity? {
        guard var identity = capture(pid),
              expectedExecutables.contains(where: { normalizedPath($0) == identity.executablePath }),
              requiredFirstArgument.map({ firstArgument(pid) == $0 }) ?? true else { return nil }
        identity.requiredFirstArgument = requiredFirstArgument
        return identity
    }

    func stillMatches() -> Bool {
        guard let info = Self.information(pid), info.pbi_uid == uid,
              info.pbi_start_tvsec == startedSeconds,
              info.pbi_start_tvusec == startedMicroseconds,
              Self.executablePath(pid) == executablePath else { return false }
        return requiredFirstArgument.map { Self.firstArgument(pid) == $0 } ?? true
    }

    @discardableResult
    func signal(_ signal: Int32) -> Bool {
        guard stillMatches() else { return false }
        return Darwin.kill(pid, signal) == 0
    }

    private static func information(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return normalizedPath(URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)))
    }

    /// KERN_PROCARGS2 starts with argc, the executable path, padding, then argv.
    /// Read the first argument to distinguish a daemon from a short-lived client
    /// using the very same executable. No arguments are logged or retained.
    private static func firstArgument(_ pid: Int32) -> String? {
        var argumentLimit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        var limitMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitMIB, UInt32(limitMIB.count), &argumentLimit, &limitSize, nil, 0) == 0,
              argumentLimit > 0, argumentLimit <= 4 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(argumentLimit))
        var byteCount = bytes.count
        var argumentsMIB: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = bytes.withUnsafeMutableBytes {
            sysctl(&argumentsMIB, UInt32(argumentsMIB.count), $0.baseAddress, &byteCount, nil, 0)
        }
        guard result == 0, byteCount > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 1 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        while cursor < byteCount, bytes[cursor] != 0 { cursor += 1 }
        while cursor < byteCount, bytes[cursor] == 0 { cursor += 1 }
        // Skip argv[0]. argv[1] may be empty, so do not skip its NUL padding.
        while cursor < byteCount, bytes[cursor] != 0 { cursor += 1 }
        guard cursor < byteCount else { return nil }
        cursor += 1
        let start = cursor
        while cursor < byteCount, bytes[cursor] != 0 { cursor += 1 }
        guard cursor < byteCount else { return nil }
        return String(bytes: bytes[start..<cursor], encoding: .utf8)
    }
}

/// Retains compatibility with the CLI's existing plain numeric PID file.
enum OwnedDaemonPIDFile {
    static func readPID(at file: URL) -> Int32? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return nil }
        return pid
    }

    static func identity(at file: URL, expectedExecutables: [URL]) -> OwnedProcessIdentity? {
        guard let pid = readPID(at: file) else { return nil }
        return OwnedProcessIdentity.capture(pid, expectedExecutables: expectedExecutables,
                                            requiredFirstArgument: "daemon")
    }

    /// A new daemon may already have replaced the file during graceful shutdown.
    static func remove(at file: URL, ifPIDMatches pid: Int32) {
        guard readPID(at: file) == pid else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
