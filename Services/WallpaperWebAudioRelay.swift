import Foundation
import Combine

// MARK: - WE Web 壁纸音频中继
//
// 把 SystemAudioCaptureService 产出的 mono 64 频段频谱，
// 镜像成 WE 标准 128 frame（0..63=L, 64..127=R），节流到 ≤30fps，
// 在持续静音时低频推零保活，通过 WallpaperEngineXBridge.sendAudioDataToWebDaemon
// 转发到 wallpaperengine-cli daemon。
//
// ═══════════════════════════════════════════════════════════
// 设计要点：
//   - 引用计数 start()/stop()：多次 start 只启动一次 SCK；归零才停。
//   - 静音保活：averageEnergy < 0.01 持续 2s 后降频发送全零帧；
//     一旦能量回升立即恢复（重置静音计时）。
//   - 节流：两次发送间隔必须 ≥ 33ms（30fps）。
//   - 错误降级：屏幕录制权限被拒 → SCK 不启动，本类无副作用，
//     壁纸继续走 daemon 端 idle-zero shim。
// ═══════════════════════════════════════════════════════════

@MainActor
public final class WallpaperWebAudioRelay {

    public static let shared = WallpaperWebAudioRelay()

    // MARK: - 调参常量

    /// 节流间隔：~30fps
    private let throttleNs: UInt64 = 33_000_000

    /// 静音阈值：averageEnergy 低于此值视为静音
    private let silenceThreshold: Float = 0.01

    /// 静音宽限：静音持续超过此值后降频推送全零帧
    private let silenceGraceNs: UInt64 = 2_000_000_000

    /// 静音保活间隔：防止 Web 端长时间重复旧频谱，保持可恢复的零输入。
    private let silentKeepAliveNs: UInt64 = 1_000_000_000

    // MARK: - 状态

    private var referenceCount: Int = 0
    private var cancellable: AnyCancellable?
    private var lastSendNs: UInt64 = 0
    private var lastSilentSendNs: UInt64 = 0
    private var silentSinceNs: UInt64? = nil

    private init() {}

    // MARK: - 启停

    /// 启动中继；引用计数 +1。首次调用启动 SCK 并订阅频谱。
    public func start() {
        referenceCount += 1
        guard referenceCount == 1 else { return }
        SystemAudioCaptureService.shared.start()
        cancellable = SystemAudioCaptureService.shared.spectrum64Publisher
            .sink { [weak self] spectrum in
                self?.handle(spectrum)
            }
    }

    /// 停止中继；引用计数 -1。归零时停止 SCK 并释放订阅。
    public func stop() {
        guard referenceCount > 0 else { return }
        referenceCount -= 1
        guard referenceCount == 0 else { return }
        cancellable?.cancel()
        cancellable = nil
        SystemAudioCaptureService.shared.stop()
        lastSendNs = 0
        lastSilentSendNs = 0
        silentSinceNs = nil
    }

    // MARK: - 帧处理

    private func handle(_ spectrum64: [Float]) {
        let now = DispatchTime.now().uptimeNanoseconds

        // 节流：30fps 上限
        if now - lastSendNs < throttleNs { return }

        // 静音判定：能量持续低于阈值 ≥ silenceGraceNs 后降频推零。
        // 不能直接停推，否则 Web shim 会持续重复最后一帧，Sonic Topography 这类壁纸会退回自循环。
        let energy = SystemAudioCaptureService.shared.averageEnergy
        if energy < silenceThreshold {
            if let since = silentSinceNs {
                if now - since > silenceGraceNs {
                    if now - lastSilentSendNs < silentKeepAliveNs { return }
                    lastSilentSendNs = now
                    sendMirroredSpectrum(Array(repeating: 0, count: 64), at: now)
                    return
                }
            } else {
                silentSinceNs = now
            }
        } else {
            silentSinceNs = nil
            lastSilentSendNs = 0
        }

        sendMirroredSpectrum(spectrum64, at: now)
    }

    private func sendMirroredSpectrum(_ spectrum64: [Float], at now: UInt64) {
        // mono → 128 镜像 + clamp 到 [0, 1]
        var buf = [Float](repeating: 0, count: 128)
        let count = min(64, spectrum64.count)
        for i in 0..<count {
            let v = max(0, min(1, spectrum64[i]))
            buf[i] = v
            buf[i + 64] = v
        }

        lastSendNs = now
        WallpaperEngineXBridge.shared.sendAudioDataToWebDaemon(buf)
    }
}
