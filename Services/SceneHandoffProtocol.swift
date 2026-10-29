import CryptoKit
import Foundation

// MARK: - Scene 安全交接协议 v1（宿主侧纯逻辑）
//
// 规格见 wallpaper-wgpu 的 `--handoff-status` 实现：渲染器把状态 JSON 原子写到
// 状态文件，宿主只认「本次 session / request / generation / contentIdentity」完全匹配、
// 且真实 surface 帧已被 GPU 确认完成的状态。本文件不依赖 AppKit，回归脚本可单独编译。

enum SceneHandoffProtocol {
    static let version = 1
    /// 渲染器二进制里必须出现的能力字面量；缺失即视为不支持安全交接。
    static let capabilityMarker = "scene-handoff-v1"
    static let requiredCapabilities: Set<String> = ["scene-handoff-v1", "surface-gpu-ack", "idempotent-commands"]

    /// bake 子命令支持与实时启动同语义的 `--crop` / `--crop-viewport`。
    static let bakeCropMarker = "bake-crop-v1"

    /// 按字节扫描渲染器二进制，判断是否带安全交接能力。
    static func binarySupportsHandoff(at url: URL) -> Bool {
        binaryContains(capabilityMarker, at: url)
    }

    /// 二进制是否包含某个能力字面量。结果按路径+mtime+size+字面量缓存。
    static func binaryContains(_ markerText: String, at url: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(markerText)|\(url.path)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((attrs?[.size] as? NSNumber)?.intValue ?? 0)"
        capabilityCacheLock.lock()
        if let cached = capabilityCache[stamp] {
            capabilityCacheLock.unlock()
            return cached
        }
        capabilityCacheLock.unlock()
        let supported: Bool
        if let data = try? Data(contentsOf: url, options: .alwaysMapped),
           let marker = markerText.data(using: .utf8) {
            supported = data.range(of: marker) != nil
        } else {
            supported = false
        }
        capabilityCacheLock.lock()
        capabilityCache[stamp] = supported
        capabilityCacheLock.unlock()
        return supported
    }

    private static let capabilityCacheLock = NSLock()
    private nonisolated(unsafe) static var capabilityCache: [String: Bool] = [:]
}

/// 渲染器写出的状态（camelCase）。
struct SceneHandoffStatus: Decodable, Equatable, Sendable {
    struct ErrorInfo: Decodable, Equatable, Sendable {
        let code: String
        let message: String?
    }

    let protocolVersion: Int
    let capabilities: [String]
    let sessionId: String
    let pid: Int32?
    let requestId: String?
    let generation: UInt64?
    let contentIdentity: String?
    let acceptedSeq: UInt64?
    let phase: String
    let contentPrepared: Bool?
    let windowOrdered: Bool?
    let surfaceGeneration: UInt64?
    let readySurfaceSeq: UInt64?
    let gpuCompletedSeq: UInt64?
    let error: ErrorInfo?
    let updatedAtMs: Double?

    static func read(from url: URL) -> SceneHandoffStatus? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(SceneHandoffStatus.self, from: data)
    }
}

/// 宿主对某一屏本次请求的期望身份。
struct SceneHandoffExpectation: Equatable, Sendable {
    let sessionID: String
    let requestID: String
    let generation: UInt64
    let contentIdentity: String
    /// show（或热重载）命令的序号；状态里的 acceptedSeq 必须不小于它。
    let minimumAcceptedSeq: UInt64
}

enum SceneHandoffReadiness: Equatable, Sendable {
    /// 状态文件尚未出现，或属于本请求但还没到 GPU 完成。
    case pending(phase: String)
    /// 本请求的真实窗口首帧已提交且 GPU 完成。
    case ready
    /// 渲染器明确报告本请求失败。
    case failed(code: String, message: String)
    /// 渲染器协议版本或能力不满足要求。
    case unsupported(String)
    /// 状态属于其它 session / 请求 / 内容（旧消息、乱序、晚到）。
    case stale

    var isTerminal: Bool {
        switch self {
        case .ready, .failed, .unsupported: return true
        case .pending, .stale: return false
        }
    }
}

extension SceneHandoffProtocol {
    /// 纯函数判定：状态是否证明「本请求」的真实窗口首帧已经 GPU 完成。
    static func evaluate(_ status: SceneHandoffStatus?, expected: SceneHandoffExpectation) -> SceneHandoffReadiness {
        guard let status else { return .pending(phase: "missing") }
        guard status.sessionId == expected.sessionID else { return .stale }
        guard status.protocolVersion == version else {
            return .unsupported("protocolVersion=\(status.protocolVersion)")
        }
        let missing = requiredCapabilities.subtracting(status.capabilities)
        guard missing.isEmpty else {
            return .unsupported("缺少能力 \(missing.sorted().joined(separator: ","))")
        }
        guard let accepted = status.acceptedSeq, accepted >= expected.minimumAcceptedSeq else {
            return .pending(phase: "awaitingAccept")
        }
        guard status.requestId == expected.requestID,
              status.generation == expected.generation,
              status.contentIdentity == expected.contentIdentity else {
            return .stale
        }
        if status.phase == "failed" || status.error != nil {
            return .failed(
                code: status.error?.code ?? "failed",
                message: status.error?.message ?? "渲染器报告失败"
            )
        }
        guard status.contentPrepared == true,
              status.windowOrdered == true,
              let ready = status.readySurfaceSeq,
              let done = status.gpuCompletedSeq,
              done >= ready else {
            return .pending(phase: status.phase)
        }
        return .ready
    }
}

/// 宿主写进 `--wallpaper-control` 的交接命令字段（与现有 setWallpaper/show 等字段合并）。
struct SceneHandoffCommand: Equatable, Sendable {
    let sessionID: String
    let commandSeq: UInt64
    let requestID: String
    let generation: UInt64
    let contentIdentity: String
    /// true = 建窗并开始提交真实 surface 帧（幂等）。
    let show: Bool

    var jsonFields: [String: Any] {
        var fields: [String: Any] = [
            "protocolVersion": SceneHandoffProtocol.version,
            "sessionId": sessionID,
            "commandSeq": commandSeq,
            "requestId": requestID,
            "generation": generation,
            "contentIdentity": contentIdentity
        ]
        if show { fields["show"] = true }
        return fields
    }

    var expectation: SceneHandoffExpectation {
        SceneHandoffExpectation(
            sessionID: sessionID,
            requestID: requestID,
            generation: generation,
            contentIdentity: contentIdentity,
            minimumAcceptedSeq: commandSeq
        )
    }
}

// MARK: - 内容 / 属性 / 几何身份

enum SceneHandoffIdentity {
    static let posterSchemaVersion = 2

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 内容版本摘要：工程根路径 + project.json 与场景主文件的 size/mtime。
    /// 只读元数据，不读整包（大工程里 scene.pkg 可达数百 MB）。
    static func contentDigest(projectRoot: String) -> String {
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL
        var parts = [root.path]
        let fm = FileManager.default
        let candidates = ["project.json", "scene.pkg", "scene.json", "gifscene.pkg"]
        for name in candidates {
            let path = root.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(name):\(size):\(Int64(mtime * 1000))")
        }
        return sha256Hex(parts.joined(separator: "|"))
    }

    /// 属性摘要：对 JSON 做键排序后的规范化表示再哈希；nil/空/无法解析按原文处理。
    static func propertiesDigest(_ json: String?) -> String {
        guard let json, !json.isEmpty else { return "none" }
        if let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: canonical, encoding: .utf8) {
            return sha256Hex(text)
        }
        return sha256Hex(json)
    }

    /// 本次交接的内容身份（渲染器回显用）。
    static func contentIdentity(contentDigest: String, propertiesDigest: String) -> String {
        String(sha256Hex("v\(posterSchemaVersion)|\(contentDigest)|\(propertiesDigest)").prefix(32))
    }

    /// 精确过渡图身份：内容 + 属性 + 像素几何 + backing scale + 裁剪配置 + schema。
    static func posterIdentity(
        contentDigest: String,
        propertiesDigest: String,
        pixelWidth: Int,
        pixelHeight: Int,
        backingScale: Double,
        cropSignature: String
    ) -> String {
        let scale = Int((backingScale * 1000).rounded())
        return sha256Hex(
            "poster-v\(posterSchemaVersion)|\(contentDigest)|\(propertiesDigest)|\(pixelWidth)x\(pixelHeight)@\(scale)|\(cropSignature)"
        )
    }
}

/// 过渡图的匹配元数据（随图片写成 sidecar JSON）。
struct SceneTransitionPosterMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let identity: String
    let contentDigest: String
    let propertiesDigest: String
    let pixelWidth: Int
    let pixelHeight: Int
    let backingScale: Double
    let cropSignature: String
    let createdAt: Date
}

/// 逐屏准备结果。
enum SceneTransitionPosterOutcome: Equatable, Sendable {
    case cacheHit(URL)
    case generated(URL)
    case failed(String)
    case cancelled
    case displayInvalid

    var imageURL: URL? {
        switch self {
        case .cacheHit(let url), .generated(let url): return url
        case .failed, .cancelled, .displayInvalid: return nil
        }
    }
}

// MARK: - 逐屏请求所有权

/// 每屏 generation：同一屏最新请求胜出；不相交显示器上的请求互不取消。
struct SceneScreenOwnershipTable: Sendable {
    struct Token: Equatable, Hashable, Sendable {
        let requestID: String
        let screenID: String
        let generation: UInt64
    }

    private(set) var generations: [String: UInt64] = [:]
    private(set) var owners: [String: String] = [:]

    /// 为一组屏幕登记新请求；返回每屏 token。
    mutating func claim(requestID: String, screenIDs: [String]) -> [String: Token] {
        var tokens: [String: Token] = [:]
        for screenID in Set(screenIDs) {
            let next = (generations[screenID] ?? 0) &+ 1
            generations[screenID] = next
            owners[screenID] = requestID
            tokens[screenID] = Token(requestID: requestID, screenID: screenID, generation: next)
        }
        return tokens
    }

    func isCurrent(_ token: Token) -> Bool {
        generations[token.screenID] == token.generation && owners[token.screenID] == token.requestID
    }

    /// 让某屏的当前请求失效（例如该屏被设成视频 / 静态图）。
    mutating func invalidate(screenID: String) {
        generations[screenID] = (generations[screenID] ?? 0) &+ 1
        owners[screenID] = nil
    }
}
