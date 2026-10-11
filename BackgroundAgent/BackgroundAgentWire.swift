import Foundation
import MachO

enum BackgroundAgentWire {
    static let bundleIdentifier = "com.waifux.app.helper"
    static let machServiceName = "com.waifux.app.helper.control"
    static let protocolVersion = 2
    static let plistName = "com.waifux.app.helper.plist"
    static let preferencesSuite = "group.com.waifux.app"
    static let migrationKey = "background_preferences_migrated_v1"
    static let maximumCommandBytes = 16 * 1024 * 1024
}

struct BackgroundAgentHello: Codable, Sendable {
    let protocolVersion: Int
    let bundleIdentifier: String
    let processIdentifier: Int32
    let runtimeReady: Bool
    var buildIdentity: String? = nil
}

/// Compare loaded code with the embedded executable. Xcode Debug uses a stable
/// launcher plus a changing .debug.dylib; both UUIDs belong to its identity.
enum BackgroundAgentBuildIdentity {
    static func running() -> String? {
        guard let header = _dyld_get_image_header(0), let commands = loadedCommands(header),
              let mainID = uuid(in: commands), let path = _dyld_get_image_name(0) else { return nil }
        let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
        guard let library = debugLibraryName(in: commands, executableName: name) else { return mainID }
        for index in 0..<_dyld_image_count() {
            guard let path = _dyld_get_image_name(index),
                  URL(fileURLWithPath: String(cString: path)).lastPathComponent == library,
                  let header = _dyld_get_image_header(index), let data = loadedCommands(header),
                  let libraryID = uuid(in: data) else { continue }
            // Read the loaded header, not the possibly rebuilt file on disk.
            return mainID + ":" + libraryID
        }
        return nil
    }

    static func executable(_ url: URL) -> String? {
        guard let commands = fileCommands(url), let mainID = uuid(in: commands) else { return nil }
        guard let name = debugLibraryName(in: commands, executableName: url.lastPathComponent) else { return mainID }
        let library = url.deletingLastPathComponent().appendingPathComponent(name)
        guard let data = fileCommands(library), let libraryID = uuid(in: data) else { return nil }
        return mainID + ":" + libraryID
    }

    private static func loadedCommands(_ header: UnsafePointer<mach_header>) -> Data? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        let size = Int(header.pointee.sizeofcmds) + MemoryLayout<mach_header_64>.size
        guard size >= 32, size <= 1024 * 1024 else { return nil }
        return Data(bytes: UnsafeRawPointer(header), count: size)
    }

    private static func fileCommands(_ url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let prefix = try? file.read(upToCount: 4096), prefix.count >= 32 else { return nil }
        var offset: UInt64 = 0
        let magic = big32(prefix, 0)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = Int(big32(prefix, 4))
            let stride = magic == 0xcafebabf ? 32 : 20
            #if arch(arm64)
            let cpu: UInt32 = 0x0100000c
            #else
            let cpu: UInt32 = 0x01000007
            #endif
            guard count > 0, count <= (prefix.count - 8) / stride else { return nil }
            guard let index = (0..<count).first(where: { big32(prefix, 8 + $0 * stride) == cpu }) else { return nil }
            let entry = 8 + index * stride
            offset = magic == 0xcafebabf ? UInt64(big32(prefix, entry + 8)) << 32 | UInt64(big32(prefix, entry + 12)) : UInt64(big32(prefix, entry + 8))
        }
        guard (try? file.seek(toOffset: offset)) != nil,
              let header = try? file.read(upToCount: 32), header.count == 32 else { return nil }
        let commandBytes = Int(little32(header, 20))
        guard commandBytes > 0, commandBytes < 1024 * 1024,
              let commands = try? file.read(upToCount: commandBytes) else { return nil }
        return header + commands
    }

    private static func debugLibraryName(in data: Data, executableName: String) -> String? {
        guard data.count >= 32, little32(data, 0) == MH_MAGIC_64 else { return nil }
        var offset = 32
        for _ in 0..<little32(data, 16) {
            guard offset + 8 <= data.count else { return nil }
            let command = little32(data, offset)
            let size = Int(little32(data, offset + 4))
            guard size >= 8, size <= data.count - offset else { return nil }
            if command == LC_LOAD_DYLIB, size >= 24 {
                let nameOffset = Int(little32(data, offset + 8))
                if nameOffset >= 24, nameOffset < size {
                    let bytes = data[(offset + nameOffset)..<(offset + size)].prefix { $0 != 0 }
                    let path = String(decoding: bytes, as: UTF8.self)
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    if name == executableName + ".debug.dylib" { return name }
                }
            }
            offset += size
        }
        return nil
    }

    private static func uuid(in data: Data) -> String? {
        guard data.count >= 32, little32(data, 0) == 0xfeedfacf else { return nil }
        var offset = 32
        for _ in 0..<little32(data, 16) {
            guard offset + 8 <= data.count else { return nil }
            let command = little32(data, offset)
            let size = Int(little32(data, offset + 4))
            guard size >= 8, size <= data.count - offset else { return nil }
            if command == 0x1b, size >= 24 {
                return data[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
            }
            offset += size
        }
        return nil
    }
    private static func little32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private static func big32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}

struct BackgroundAgentCommand: Codable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let operation: String
    let arguments: Data

    init(operation: String, arguments: Data = Data(), requestID: String = UUID().uuidString) {
        self.protocolVersion = BackgroundAgentWire.protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.arguments = arguments
    }
}

struct BackgroundAgentReply: Codable, Sendable {
    let requestID: String
    let result: Data?
    let error: String?
}

enum BackgroundPropertyList {
    static func encode(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        if data.isEmpty { return [:] }
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
    }
}

@objc protocol BackgroundAgentXPC {
    func hello(_ reply: @escaping @Sendable (NSData) -> Void)
    func prepareForUpgrade(_ reply: @escaping @Sendable (NSData) -> Void)
    func perform(_ command: NSData, reply: @escaping @Sendable (NSData) -> Void)
    func subscribe(_ reply: @escaping @Sendable (NSData) -> Void)
}

@objc protocol BackgroundAgentObserver {
    func snapshotChanged(_ data: NSData)
    func openUI(_ action: String)
}

extension Notification.Name {
    static let backgroundDownloadWorkersChanged = Notification.Name("com.waifux.helper.downloadWorkersChanged")
    static let backgroundAgentSnapshotChanged = Notification.Name("com.waifux.helper.snapshot")
}
