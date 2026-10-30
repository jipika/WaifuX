import Foundation
import AppKit
import Darwin

/// Wallpaper Engine 手机推送：we-mpkg-tool 转码 + 官方 App 配对推送（python 服务端打包版）
///
/// 链路（全部真机验证过）：
/// 1. 转码：App 内嵌 `we-mpkg-tool`（PyInstaller 单文件）把 workshop 工程目录转成 mpkg
///    （主图 ETC2_RGBA 半分辨率、遮罩原格式、texW/imgW 保原尺寸、video 原样并入）
/// 2. 推送：App 内嵌 `we-pair-server`（同款打包），UDP 组播 239.100.0.1:7884 广播 +
///    TCP 7889（手动添加）/7866（自动发现）+ RSA/AES/PIN 配对 + mpkg 分块推送
/// 3. 手机侧：官方 Wallpaper Engine App「配对页」发现/手动添加 → 输 PIN → 自动收包
@MainActor
final class MobilePushService: ObservableObject {
    static let shared = MobilePushService()

    enum PushPhase: Equatable {
        case idle
        case converting(progress: Double)
        case waitingPairing(pin: String)
        case pushing(name: String, progress: Double)
        case done
        case failed(String)
    }

    @Published private(set) var phase: PushPhase = .idle
    @Published private(set) var serverLog: [String] = []

    /// 服务端子进程（转码/推送期间保活）
    private var serverProcess: Process?
    private var serverPipe: Pipe?
    /// 转码子进程
    private var convertProcess: Process?

    private let queue = DispatchQueue(label: "waifux.mobilepush", qos: .userInitiated)

    private init() {}

    // MARK: - 工具二进制定位（与 RendererComponentStore 同套路）

    /// universal 包同时携带 arm64 与 x86_64 两版推送工具（PyInstaller 单文件不能 lipo
    /// 合并 —— bootloader 靠文件尾 cookie 定位内嵌归档，fat 化会失效），靠它挑对应那份。
    nonisolated static var isX86_64Process: Bool {
#if arch(x86_64)
        return true
#else
        // Apple Silicon 上也可能被 Rosetta 拉起（Finder 里勾了「用 Rosetta 打开」）
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 else {
            return false
        }
        return translated == 1
#endif
    }

    nonisolated static func toolURL(named name: String) -> URL? {
        // 优先按进程架构挑后缀件；单架构包里后缀件已被 package.sh 换装掉，这里自然落空。
        if isX86_64Process, let url = toolURL(exactName: "\(name)-x86_64") {
            return url
        }
        return toolURL(exactName: name)
    }

    nonisolated private static func toolURL(exactName name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources/\(name)"),
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            return c
        }
        if let resourceURL = Bundle.main.resourceURL {
            let c = resourceURL.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: c.path) {
                return c
            }
        }
        // 开发期：仓库 Tools/MobilePush/ 同级
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Tools/MobilePush/\(name)")
        if FileManager.default.isExecutableFile(atPath: dev.path) {
            return dev
        }
        return nil
    }

    // MARK: - 转码

    /// 把工程目录转成 mpkg；返回 mpkg 落盘位置（Downloads/WaifuXPush/<title>.mpkg）
    func convertProject(_ projectRoot: URL, title: String) async throws -> URL {
        guard let tool = Self.toolURL(named: "we-mpkg-tool") else {
            throw PushError.toolMissing("we-mpkg-tool")
        }
        let outDir = DownloadPathManager.shared.rootFolderURL
            .appendingPathComponent("WaifuXPush", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(of: "/", with: "_")
        let outURL = outDir.appendingPathComponent("\(safeTitle).mpkg")

        await MainActor.run { phase = .converting(progress: 0) }

        let process = Process()
        process.executableURL = tool
        process.arguments = [projectRoot.path, outURL.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        convertProcess = process
        defer { convertProcess = nil }

        try process.run()
        // 转码是单任务（秒级），进度只做粗粒度
        await MainActor.run { phase = .converting(progress: 0.5) }
        let status = await waitForExit(process, stderrPipe: stderrPipe)
        guard status == 0, FileManager.default.fileExists(atPath: outURL.path) else {
            let msg = readTail(stderrPipe)
            throw PushError.convertFailed(msg)
        }
        await MainActor.run { phase = .converting(progress: 1) }
        return outURL
    }

    // MARK: - 推送

    /// 起服务端并推送一批 mpkg。PIN 由服务端生成，通过回调交 UI 展示。
    func startPush(files: [(url: URL, title: String)]) async throws -> String {
        guard let server = Self.toolURL(named: "we-pair-server") else {
            throw PushError.toolMissing("we-pair-server")
        }
        // 先杀残留实例（端口占用）
        Self.killStaleServer()

        let process = Process()
        process.executableURL = server
        var args = ["7866"]
        for f in files {
            args.append("\(f.url.path):\(f.title)")
        }
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        let env = ProcessInfo.processInfo.environment
        process.environment = env.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }
        serverProcess = process
        serverPipe = outPipe

        // 逐行读日志：抓 PIN / 配对 / 进度
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.ingestLog(text)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.serverPipe?.fileHandleForReading.readabilityHandler = nil
                self?.serverProcess = nil
            }
        }
        try process.run()

        // 等 PIN 出现在日志（最多 5s）
        let pin = await waitPIN()
        guard let pin else {
            throw PushError.pinTimeout(readTail(outPipe))
        }
        await MainActor.run { phase = .waitingPairing(pin: pin) }
        return pin
    }

    /// 推送取消/收尾
    func stopPush() {
        Self.killStaleServer()
        serverProcess = nil
        phase = .idle
    }

    private static func killStaleServer() {
        // 打包版命令行 ".../we-pair-server 7866 ..."（无 .py），源码版是 ".../we-pair-server.py 7866 ..."
        // 统一按 "we-pair-server" 片段匹配两种形态
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "we-pair-server"]
        try? task.run()
        task.waitUntilExit()
        // pkill 是异步生效的，等端口真正释放（最多 3s）
        for _ in 0..<30 {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            probe.arguments = ["-iTCP:7889", "-sTCP:LISTEN"]
            probe.standardOutput = Pipe()
            probe.standardError = Pipe()
            try? probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus != 0 { break }   // 没人监听了
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private var pendingLog = ""
    private func ingestLog(_ chunk: String) {
        pendingLog += chunk
        // 服务端推送进度用 \r 结尾(同行刷新), 也可能混 \n — 统一按 \r 和 \n 双分隔切
        while let idx = pendingLog.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(pendingLog[..<idx])
            pendingLog = String(pendingLog[pendingLog.index(after: idx)...])
            serverLog.append(line)
            if serverLog.count > 400 { serverLog.removeFirst(serverLog.count - 400) }
            // 落盘副本：设置页「导出日志」会合并带上（诊断手机配对/推送用）
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".waifux", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let logURL = dir.appendingPathComponent("pair-server-client.log")
            let data = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: logURL)
            }
            if line.contains("PIN:") {
                let pin = line.components(separatedBy: "PIN:")[1]
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(4)
                pendingPIN = String(pin)
            }
            if line.contains("配对成功") {
                phase = .pushing(name: "传输中", progress: 0)
            }
            if line.contains("等待手机重连"), case .waitingPairing(let pin) = phase {
                phase = .waitingPairing(pin: pin)
            }
            // 推送进度: "  标题: 34% (3840KB/11267KB)"
            if line.contains("%"), line.contains("KB/"), case .pushing(let name, _) = phase {
                if let pctPart = line.components(separatedBy: "%").first,
                   let lastNum = pctPart.split(separator: " ").last,
                   let pct = Double(lastNum.replacingOccurrences(of: "%", with: "")) {
                    phase = .pushing(name: name, progress: min(1.0, pct / 100.0))
                }
            }
            if line.contains("完成 "), line.contains("B in") {
                // 一个包推完 → 推进度按包数粗算（单包=100%）
                if case .pushing(let name, _) = phase {
                    phase = .pushing(name: name, progress: 1)
                }
            }
            if line.contains("连接保持") || line.contains("全部推送完成") {
                phase = .done
            }
            if line.contains("PIN 不对") {
                if case .waitingPairing(let pin) = phase {
                    phase = .failed("PIN 不对，请在手机上重新输入 \(pin)")
                }
            }
        }
    }

    private var pendingPIN: String?

    private func waitPIN() async -> String? {
        // PyInstaller 版冷启 ~9s（cryptography/RSA 初始化 + 双端口 bind），5s 太短
        for _ in 0..<200 {
            if let pin = pendingPIN { return pin }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return pendingPIN
    }

    private func waitForExit(_ process: Process, stderrPipe: Pipe?) async -> Int32 {
        await withCheckedContinuation { cont in
            process.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus)
            }
        }
    }

    private func readTail(_ pipe: Pipe?) -> String {
        guard let pipe else { return "" }
        let data = pipe.fileHandleForReading.availableData
        return String(data: data, encoding: .utf8) ?? ""
    }

    enum PushError: LocalizedError {
        case toolMissing(String)
        case convertFailed(String)
        case pinTimeout(String)

        var errorDescription: String? {
            switch self {
            case .toolMissing(let name):
                return "缺少内嵌工具 \(name)"
            case .convertFailed(let log):
                return "转码失败：\(log)"
            case .pinTimeout:
                return "服务端未在 20 秒内报告配对码"
            }
        }
    }
}
