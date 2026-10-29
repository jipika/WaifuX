import Foundation

// 编译运行：
// swiftc -parse-as-library -swift-version 6 Services/SceneHandoffProtocol.swift \
//   Tests/SceneHandoffProtocolRegression.swift -o /tmp/scene-handoff-regression && /tmp/scene-handoff-regression

@main
struct SceneHandoffProtocolRegression {
    static func status(_ json: String) -> SceneHandoffStatus {
        try! JSONDecoder().decode(SceneHandoffStatus.self, from: Data(json.utf8))
    }

    static func body(
        session: String = "s1", request: String = "r1", generation: Int = 3,
        identity: String = "c1", accepted: Int = 2, phase: String = "gpuCompleted",
        prepared: Bool = true, ordered: Bool = true, ready: String = "17", done: String = "17",
        caps: String = #""scene-handoff-v1","defer-show","surface-gpu-ack","idempotent-commands""#,
        version: Int = 1, error: String = "null"
    ) -> String {
        """
        {"protocolVersion":\(version),"capabilities":[\(caps)],"sessionId":"\(session)","pid":1,
         "requestId":"\(request)","generation":\(generation),"contentIdentity":"\(identity)",
         "acceptedSeq":\(accepted),"phase":"\(phase)","contentPrepared":\(prepared),
         "windowOrdered":\(ordered),"surfaceGeneration":1,"readySurfaceSeq":\(ready),
         "gpuCompletedSeq":\(done),"error":\(error),"updatedAtMs":1}
        """
    }

    static func main() {
        let expected = SceneHandoffExpectation(
            sessionID: "s1", requestID: "r1", generation: 3, contentIdentity: "c1", minimumAcceptedSeq: 2
        )
        func eval(_ json: String) -> SceneHandoffReadiness {
            SceneHandoffProtocol.evaluate(status(json), expected: expected)
        }

        // 完整证据 → ready
        precondition(eval(body()) == .ready)
        // 缺状态文件 → pending
        precondition(SceneHandoffProtocol.evaluate(nil, expected: expected) == .pending(phase: "missing"))
        // 旧 session / 旧请求 / 旧 generation / 旧内容 → stale（晚到消息不能放行）
        precondition(eval(body(session: "old")) == .stale)
        precondition(eval(body(request: "r0")) == .stale)
        precondition(eval(body(generation: 2)) == .stale)
        precondition(eval(body(identity: "c0")) == .stale)
        // 命令还没被接受（acceptedSeq 落后）→ pending，即使其它字段看起来就绪
        precondition(eval(body(accepted: 1)) == .pending(phase: "awaitingAccept"))
        // 冷启动提前确认 show 只证明命令接受，尚无 GPU / scene / window 时仍是 loading，不能放行。
        let coldExpected = SceneHandoffExpectation(
            sessionID: "s1", requestID: "r1", generation: 3, contentIdentity: "c1", minimumAcceptedSeq: 1
        )
        let coldLoading = status(body(
            accepted: 1, phase: "loading", prepared: false, ordered: false, ready: "null", done: "0"
        ))
        precondition(SceneHandoffProtocol.evaluate(coldLoading, expected: coldExpected) == .pending(phase: "loading"))
        // 离屏完成 / 未建窗 / 无真实 surface 帧 / GPU 未完成 → 都不能算 ready
        precondition(eval(body(phase: "contentPrepared", ordered: false, ready: "null", done: "null")) != .ready)
        precondition(eval(body(prepared: false)) != .ready)
        precondition(eval(body(ready: "null", done: "12")) != .ready)
        precondition(eval(body(phase: "surfaceSubmitted", ready: "17", done: "16")) != .ready)
        // 热重载失败 → failed（不能沿用旧场景 ready）
        precondition(eval(body(phase: "failed", error: #"{"code":"reload_failed","message":"x"}"#))
            == .failed(code: "reload_failed", message: "x"))
        // 协议不匹配 → unsupported
        if case .unsupported = eval(body(version: 2)) {} else { preconditionFailure("version") }
        if case .unsupported = eval(body(caps: #""defer-show""#)) {} else { preconditionFailure("caps") }

        // 属性摘要：键顺序无关，值变化敏感
        let a = SceneHandoffIdentity.propertiesDigest(#"{"a":1,"b":{"c":2}}"#)
        let b = SceneHandoffIdentity.propertiesDigest(#"{"b":{"c":2},"a":1}"#)
        let c = SceneHandoffIdentity.propertiesDigest(#"{"a":2,"b":{"c":2}}"#)
        precondition(a == b && a != c)
        precondition(SceneHandoffIdentity.propertiesDigest(nil) == SceneHandoffIdentity.propertiesDigest(""))

        // 过渡图身份：几何 / scale / 裁剪 任一变化都换身份
        func poster(_ w: Int, _ h: Int, _ s: Double, _ crop: String) -> String {
            SceneHandoffIdentity.posterIdentity(
                contentDigest: "d", propertiesDigest: a, pixelWidth: w, pixelHeight: h,
                backingScale: s, cropSignature: crop
            )
        }
        let base = poster(3200, 1800, 2, "none")
        precondition(base == poster(3200, 1800, 2, "none"))
        precondition(base != poster(1800, 3200, 2, "none"))
        precondition(base != poster(3200, 1800, 1, "none"))
        precondition(base != poster(3200, 1800, 2, "crop:0,0,1,1"))

        // 逐屏所有权：同屏最新胜出，不相交屏互不影响
        var table = SceneScreenOwnershipTable()
        let first = table.claim(requestID: "A", screenIDs: ["s1", "s2"])
        let second = table.claim(requestID: "B", screenIDs: ["s2"])
        precondition(table.isCurrent(first["s1"]!))
        precondition(!table.isCurrent(first["s2"]!))
        precondition(table.isCurrent(second["s2"]!))
        table.invalidate(screenID: "s1")
        precondition(!table.isCurrent(first["s1"]!))
        precondition(table.isCurrent(second["s2"]!))

        print("Scene handoff protocol regression passed")
    }
}
