import AppKit
import Combine
import Foundation

/// The UI owns no wallpaper runtime. Commands enter one ordered XPC stream.
@MainActor
enum BackgroundRuntimeBridge {
    /// 库快照到达位：菜单栏弹窗等轻量 UI 不想引 BackgroundAgentClient 的完整订阅面。
    /// Helper 进程内库记录本地直读，不存在「快照未到达」态。
    static var librarySnapshotIsArrived: Bool {
        #if WAIFUX_HELPER
        true
        #else
        BackgroundAgentClient.shared.librarySnapshotIsArrived
        #endif
    }

    /// 库快照到达位的变化流（UI 侧订阅用）。
    static var librarySnapshotArrivedPublisher: AnyPublisher<Bool, Never> {
        #if WAIFUX_HELPER
        Just(true).eraseToAnyPublisher()
        #else
        BackgroundAgentClient.shared.$librarySnapshotIsArrived.eraseToAnyPublisher()
        #endif
    }

    /// 主动拉取一帧库快照（与库页同一 RPC）；Helper 本地库即是真值，无需拉取。
    static func refreshLibrarySnapshot() async throws {
        #if !WAIFUX_HELPER
        try await BackgroundAgentClient.shared.refreshLibrarySnapshot()
        #endif
    }

    static func arguments(_ values: [String: Any?]) -> [String: Any] {
        values.compactMapValues { value in
            if let url = value as? URL { return url.absoluteString }
            if let screen = value as? NSScreen { return ["id": screen.wallpaperScreenIdentifier, "fingerprint": screen.wallpaperScreenFingerprint] }
            if let screens = value as? [NSScreen] { return screens.map { ["id": $0.wallpaperScreenIdentifier, "fingerprint": $0.wallpaperScreenFingerprint] } }
            if let strings = value as? Set<String> { return Array(strings) }
            return value
        }
    }

    static func send(_ operation: String, _ values: [String: Any?] = [:]) {
        #if !WAIFUX_HELPER
        BackgroundAgentClient.shared.send(operation, arguments(values))
        #endif
    }

    static func request(_ operation: String, _ values: [String: Any?] = [:]) async throws -> [String: Any] {
        #if WAIFUX_HELPER
        throw NSError(domain: "WaifuXHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Helper cannot send a UI command to itself"])
        #else
        return try await BackgroundAgentClient.shared.request(operation, arguments(values))
        #endif
    }

    static func requestVoid(_ operation: String, arguments: Data = Data()) async throws {
        _ = try await request(operation, BackgroundPropertyList.decode(arguments))
    }

    static func requestCodable<T: Decodable & Sendable>(_ operation: String, arguments: Data, resultKey: String, as type: T.Type) async throws -> T {
        let result = try await request(operation, BackgroundPropertyList.decode(arguments))
        guard let bytes = result[resultKey] as? Data else { throw CocoaError(.coderValueNotFound) }
        return try JSONDecoder().decode(type, from: bytes)
    }

    static func observeLibrary(_ handler: @escaping ([String: Any]) -> Void) {
        #if !WAIFUX_HELPER
        BackgroundAgentClient.shared.observeLibrary(handler)
        #endif
    }

    static func observe(_ handler: @escaping ([String: Any]) -> Void) {
        #if !WAIFUX_HELPER
        BackgroundAgentClient.shared.observe(handler)
        #endif
    }
}
