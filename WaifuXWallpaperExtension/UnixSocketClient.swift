//  Unix Socket IPC 客户端（扩展侧）
//
//  连接到主 App 的 Unix Domain Socket 服务端，查询视频信息和路径。
//  替代扫描共享容器文件的方式，避免复制视频文件。

import Foundation

// MARK: - IPC 协议类型（扩展侧定义，与服务端兼容）

struct IPCRequest: Codable {
    let id: String
    let method: String
    let params: [String: String]?
}

struct IPCVideoInfo: Codable {
    let id: String
    let name: String
    let videoPath: String
    let thumbnailPath: String
}

struct IPCResponse: Codable {
    let id: String
    let videos: [IPCVideoInfo]?
    let videoPath: String?
    let error: String?
}

/// App 推送给扩展的命令（poll_commands 响应）
struct IPCCommand: Codable {
    let action: String
    let videoID: String?
    let displayID: UInt32?
    let requestID: String?
}

/// Unix Socket IPC 客户端
///
/// 连接主 App 的 `WallpaperExtensionSocketServer`，发送 JSON 请求并接收响应。
/// 如果 App 不在运行，连接会超时或失败，此时返回 nil/空数据。
///
/// 同时支持 sync（阻塞，给 acquire() 用）和 async 调用。
final class UnixSocketClient: Sendable {
    static let shared = UnixSocketClient()

    private static let timeoutSec: Double = 5.0

    private init() {}

    /// Socket 文件路径
    private static var socketPath: String? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")?
            .appendingPathComponent("socket/extension.ipc")
            .path
    }

    // MARK: - 异步请求方法

    /// 获取所有可用视频
    func fetchVideos() async -> [IPCVideoInfo] {
        guard let response = await send(method: "list_videos") else { return [] }
        return response.videos ?? []
    }

    /// 通知 App 某个视频被选中（selectedChoicesDidChange 时调用）
    func notifyVideoSelected(_ videoID: String) async {
        _ = await send(method: "set_active_video", params: ["videoID": videoID])
    }

    /// Same request envelope; a distinct method fails closed against older hosts.
    func notifySourcePending(displayID: UInt32, requestID: String, missingContext: Bool = false) async {
        var params = ["displayID": String(displayID), "requestID": requestID]
        // Decoder/prime delays are also pending, but must never request a context rebuild.
        if missingContext { params["reason"] = "missing_context" }
        _ = await send(method: "source_pending", params: params)
    }

    func notifySourceReady(displayID: UInt32, requestID: String, success: Bool) async {
        _ = await send(method: "source_ready", params: [
            "displayID": String(displayID), "requestID": requestID,
            "success": success ? "1" : "0"
        ])
    }

    /// 向 App 注册 IOSurface ID（每显示器双缓冲），同时通知管线就绪
    func registerSurfaces(displayID: UInt32, surfaceID0: IOSurfaceID, surfaceID1: IOSurfaceID, videoID: String) async -> Bool {
        guard let response = await send(method: "register_surfaces", params: [
            "displayID": "\(displayID)",
            "surfaceID0": "\(surfaceID0)",
            "surfaceID1": "\(surfaceID1)",
            "videoID": videoID,
        ]) else {
            return false
        }
        return response.error == nil
    }

    // MARK: - 同步请求方法（用于 acquire 等同步上下文）

    /// 同步获取视频路径。阻塞当前线程直到响应返回或超时。
    /// 返回共享容器中已复制好的视频文件路径。
    func fetchVideoPathSync(for videoID: String) -> String? {
        guard let socketPath = Self.socketPath else { return nil }
        let request = IPCRequest(id: UUID().uuidString, method: "get_video_path", params: ["videoID": videoID])
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        let response = sendSync(socketPath: socketPath, data: data)
        return response?.videoPath
    }

    // MARK: - 底层通信

    private func send(method: String, params: [String: String]? = nil) async -> IPCResponse? {
        guard let socketPath = Self.socketPath else { return nil }
        let request = IPCRequest(id: UUID().uuidString, method: method, params: params)
        guard let requestData = try? JSONEncoder().encode(request) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = self.sendSync(socketPath: socketPath, data: requestData)
                continuation.resume(returning: result)
            }
        }
    }

    /// 同步发送请求并等待响应（阻塞当前线程）
    private func sendSync(socketPath: String, data: Data) -> IPCResponse? {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        // 防止写入已断开的 socket 时触发 SIGPIPE
        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // 设置超时
        var timeval = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))

        // 连接
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            Darwin.strncpy(&addr.sun_path.0, src, MemoryLayout.size(ofValue: addr.sun_path))
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafeMutablePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, addrLen) } }) == 0 else { return nil }

        // 发送 4 字节长度前缀 + JSON 数据
        var len = UInt32(data.count).bigEndian
        guard write(sock, &len, 4) == 4 else { return nil }
        guard data.withUnsafeBytes({ ptr in write(sock, ptr.baseAddress!, data.count) }) == data.count else { return nil }

        // 读取响应长度前缀
        var respLenBytes: UInt32 = 0
        guard read(sock, &respLenBytes, 4) == 4 else { return nil }
        let respLen = Int(UInt32(bigEndian: respLenBytes))
        guard respLen > 0, respLen < 1_000_000 else { return nil }

        // 读取响应 JSON
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: respLen, alignment: 1)
        defer { buf.deallocate() }
        var totalRead = 0
        while totalRead < respLen {
            let n = read(sock, buf.baseAddress! + totalRead, respLen - totalRead)
            guard n > 0 else { break }
            totalRead += n
        }
        guard totalRead == respLen else { return nil }
        let respData = Data(bytes: buf.baseAddress!, count: respLen)
        return try? JSONDecoder().decode(IPCResponse.self, from: respData)
    }
}
