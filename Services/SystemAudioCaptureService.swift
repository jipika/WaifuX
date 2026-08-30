import Foundation
import Accelerate
import AppKit
import Combine
import CoreAudio
import AudioToolbox

// MARK: - 系统音频捕获服务
//
// 使用 CoreAudio Process Tap（macOS 14.4+）捕获系统音频输出，
// 经 vDSP FFT 转换为频谱数据。
//
// ═══════════════════════════════════════════════════════════
// 捕获方式：
//   CATapDescription + AudioHardwareCreateProcessTap
//   → 捕获系统全局音频输出 mixdown（Spotify/浏览器/游戏等）
//   → 无需虚拟环回驱动
//   → 无需屏幕录制权限（不同于早期 ScreenCaptureKit 方案）
//   → 通过 Aggregate Device + AudioDeviceIOProc 回调读取 PCM
//
// 性能：
//   - 启动后系统直接以原生采样率推送 Float32 PCM
//   - 处理在 IOProc 回调线程（CoreAudio 实时线程）执行
//   - 平滑系数避免视觉闪烁
// ═══════════════════════════════════════════════════════════

@MainActor
public final class SystemAudioCaptureService: NSObject, ObservableObject {
    public static let shared = SystemAudioCaptureService()

    // MARK: - 频谱数据（高频，隔离：不走 @Published，避免 30fps objectWillChange 污染所有观察者）

    /// 16 频段频谱（0~1）—— 通过 spectrum16Publisher 推送，仅音频可视化组件订阅
    public private(set) var spectrum16: [Float] = .init(repeating: 0, count: 16)
    /// 32 频段频谱（0~1）
    public private(set) var spectrum32: [Float] = .init(repeating: 0, count: 32)
    /// 64 频段频谱（0~1）
    public private(set) var spectrum64: [Float] = .init(repeating: 0, count: 64)

    /// 频谱 Publisher（CurrentValueSubject：新订阅者立即获得最新值）
    public let spectrum16Publisher = CurrentValueSubject<[Float], Never>(Array(repeating: 0, count: 16))
    public let spectrum32Publisher = CurrentValueSubject<[Float], Never>(Array(repeating: 0, count: 32))
    public let spectrum64Publisher = CurrentValueSubject<[Float], Never>(Array(repeating: 0, count: 64))

    // MARK: - 低频状态（@Published 安全：变化频率低）

    /// 是否正在捕获音频
    @Published public private(set) var isRunning = false

    /// 当前音频能量级别
    @Published public private(set) var averageEnergy: Float = 0

    // MARK: - 私有状态

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let tapUUID = UUID()

    // MARK: 默认输出设备切换（蓝牙耳机等）
    //
    // Process Tap 绑定创建时的默认输出设备；系统切换默认输出后 tap 可能钉死
    // 旧设备，频谱能量恒 0（与 scene 端 wallpaper-wgpu #105 同源的问题）。
    // 监听 kAudioHardwarePropertyDefaultOutputDevice，防抖后整体重建 tap。
    // web 壁纸全系统只有这一份捕获，重建代价 ~几十 ms。

    /// 防抖：蓝牙切换会连发多次属性变化，合并为一次重建
    nonisolated(unsafe) fileprivate static let deviceSwitchDebounceNs: UInt64 = 300_000_000
    /// tap 启动失败退避基数（0.5s × attempt）
    nonisolated(unsafe) fileprivate static let tapRetryBaseDelayNs: UInt64 = 500_000_000
    nonisolated(unsafe) fileprivate static let tapStartMaxAttempts = 3

    nonisolated(unsafe) private static let deviceListenerQueue = DispatchQueue(label: "com.waifux.audio-devicelistener")

    /// 会话代号：每次 start/重建递增，旧的启动重试循环发现代号过期自动退出
    private var tapGeneration: UInt64 = 0
    private var deviceSwitchDebounceTask: Task<Void, Never>?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var systemAudioPermissionAlertShown = false

    nonisolated(unsafe) fileprivate static let fftSize: Int = 2048
    nonisolated(unsafe) fileprivate static let fftSizeLog2: Int = 11

    /// 用于让 FFT 线程能访问 self 上的 @Published 属性
    nonisolated(unsafe) private static var sharedRef: SystemAudioCaptureService?

    /// 平滑系数（0~1，越大越敏感）
    nonisolated(unsafe) fileprivate static let smoothFactor: Float = 0.30

    /// 缓存上一帧的频谱值用于平滑
    private var lastSpectrum16: [Float] = .init(repeating: 0, count: 16)
    private var lastSpectrum32: [Float] = .init(repeating: 0, count: 32)
    private var lastSpectrum64: [Float] = .init(repeating: 0, count: 64)

    /// FFT 处理队列
    nonisolated(unsafe) fileprivate static let fftQueue = DispatchQueue(label: "com.waifux.audio-fft", qos: .userInitiated)

    /// 权限是否已获取
    @Published public private(set) var isAuthorized = false

    // MARK: - FFT 缓存（避免每帧重建）

    nonisolated(unsafe) fileprivate static var fftSetup: FFTSetup?
    nonisolated(unsafe) fileprivate static var hannWindow: [Float] = []

    /// IOProc 实时线程用的预分配 buffer（无 malloc）
    /// 8192 frames × 2 channels = 16384 floats = 64KB，足够单次回调
    nonisolated(unsafe) fileprivate static let ioBufferCapacity: Int = 16384
    nonisolated(unsafe) fileprivate static var ioBuffer: UnsafeMutablePointer<Float> = .allocate(capacity: 16384)

    /// 复用的 FFT 工作 buffer（避免每帧堆分配）
    nonisolated(unsafe) fileprivate static let fftChunk: UnsafeMutablePointer<Float> = .allocate(capacity: 2048)
    nonisolated(unsafe) fileprivate static let fftReal: UnsafeMutablePointer<Float> = .allocate(capacity: 1024)
    nonisolated(unsafe) fileprivate static let fftImag: UnsafeMutablePointer<Float> = .allocate(capacity: 1024)
    nonisolated(unsafe) fileprivate static let fftMag: UnsafeMutablePointer<Float> = .allocate(capacity: 1024)
    nonisolated(unsafe) fileprivate static let fftWindowed: UnsafeMutablePointer<Float> = .allocate(capacity: 2048)
    nonisolated(unsafe) fileprivate static let fftDb: UnsafeMutablePointer<Float> = .allocate(capacity: 1024)

    /// FFT 处理派发节流：仅当 ring 中已累积 ≥ fftSize 才派发（避免空 dispatch）
    nonisolated(unsafe) fileprivate static var fftWorkPending: Bool = false

    /// UI 更新节流（~30fps）
    nonisolated(unsafe) fileprivate static var lastUIUpdateTime: UInt64 = 0
    nonisolated private static let uiUpdateIntervalNs: UInt64 = 33_000_000 // ~30fps

    private override init() {
        super.init()
        Self.sharedRef = self
    }

    // MARK: - 启停控制

    /// 启动音频捕获（失败时带退避自动重试）
    public func start() {
        guard !isRunning else { return }
        tapGeneration &+= 1
        let gen = tapGeneration
        Task { await runTapSession(gen: gen) }
    }

    /// 停止音频捕获并释放资源
    public func stop() {
        guard isRunning else { return }
        tapGeneration &+= 1
        deviceSwitchDebounceTask?.cancel()
        deviceSwitchDebounceTask = nil
        stopCoreAudioTap()
        isRunning = false
        resetSpectrum()
    }

    /// 启动 tap；失败时退避重试（tap 创建是系统调用，偶发失败重试即可恢复）。
    /// generation 过期（期间发生了 stop/新重建）时静默退出，避免新旧会话互踩。
    private func runTapSession(gen: UInt64) async {
        var attempt = 0
        while attempt < Self.tapStartMaxAttempts {
            guard gen == tapGeneration, !isRunning else { return }
            if startCoreAudioTap() { return }
            attempt += 1
            guard gen == tapGeneration else { return }
            try? await Task.sleep(nanoseconds: Self.tapRetryBaseDelayNs * UInt64(attempt))
            guard gen == tapGeneration else { return }
        }
        print("[AudioCapture] ❌ process tap start failed after \(attempt) attempts")
        presentSystemAudioPermissionAlert()
    }

    private func resetSpectrum() {
        lastSpectrum16 = .init(repeating: 0, count: 16)
        lastSpectrum32 = .init(repeating: 0, count: 32)
        lastSpectrum64 = .init(repeating: 0, count: 64)
        spectrum16 = .init(repeating: 0, count: 16)
        spectrum32 = .init(repeating: 0, count: 32)
        spectrum64 = .init(repeating: 0, count: 64)
        spectrum16Publisher.send(spectrum16)
        spectrum32Publisher.send(spectrum32)
        spectrum64Publisher.send(spectrum64)
        averageEnergy = 0
    }

    // MARK: - CoreAudio Tap 启停（macOS 14.4+）
    //
    // 参考 BasedHardware/omi 的 SystemAudioCaptureService 实现：
    //   1) CATapDescription(stereoGlobalTapButExcludeProcesses: []) — 抓全局系统音频
    //   2) Tap-only Aggregate Device（无 master sub-device，TapAutoStart=true）
    //   3) AudioDeviceCreateIOProcIDWithBlock + AudioDeviceStart
    //
    // 关键：必须用 stereoGlobalTapButExcludeProcesses 而不是 stereoMixdownOfProcesses
    // 或 processes:deviceUID:stream:。前者是唯一能在 IOProc 模式下拿到非零数据的 init。

    private func startCoreAudioTap() -> Bool {
        // 预创建 FFT 资源
        if Self.fftSetup == nil {
            Self.fftSetup = vDSP_create_fftsetup(vDSP_Length(Self.fftSizeLog2), FFTRadix(kFFTRadix2))
        }
        if Self.hannWindow.isEmpty {
            Self.hannWindow = [Float](repeating: 0, count: Self.fftSize)
            vDSP_hann_window(&Self.hannWindow, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        }

        // 1) 创建 Process Tap — stereoGlobalTapButExcludeProcesses 抓全局系统音频
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = tapUUID
        tapDescription.name = "WaifuX System Audio Tap"
        tapDescription.muteBehavior = .unmuted  // 不影响系统正常播放

        var tap: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else {
            print("[AudioCapture] ❌ AudioHardwareCreateProcessTap failed: OSStatus=\(err)")
            return false
        }
        self.tapID = tap

        // 2) 创建 Tap-only Aggregate Device（无 master，TapAutoStart=true）
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "WaifuX System Audio Tap Device",
            kAudioAggregateDeviceUIDKey as String: "com.waifux.systemaudio.\(tapUUID.uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey as String: NSNumber(value: 1),
                    kAudioSubTapDriftCompensationQualityKey as String: NSNumber(value: kAudioAggregateDriftCompensationMaxQuality),
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: true
        ]

        var aggregate: AudioObjectID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard err == noErr, aggregate != kAudioObjectUnknown else {
            print("[AudioCapture] ❌ AudioHardwareCreateAggregateDevice failed: OSStatus=\(err)")
            stopCoreAudioTap()
            return false
        }
        self.aggregateDeviceID = aggregate

        // 3) 注册 IOProc — 用纯 C 函数指针，避免 Swift @MainActor 隔离检查在实时线程 trap
        Self.sharedRef = self
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcID(aggregate, audioIOProc_C, nil, &procID)
        guard err == noErr, let procID else {
            print("[AudioCapture] ❌ AudioDeviceCreateIOProcID failed: OSStatus=\(err)")
            stopCoreAudioTap()
            return false
        }
        self.ioProcID = procID

        err = AudioDeviceStart(aggregate, procID)
        guard err == noErr else {
            print("[AudioCapture] ❌ AudioDeviceStart failed: OSStatus=\(err)")
            stopCoreAudioTap()
            return false
        }

        // 4) 监听默认输出设备变化（蓝牙耳机切换时重建 tap，避免钉死旧设备）
        installDefaultOutputListener()

        self.isRunning = true
        self.isAuthorized = true
        self.systemAudioPermissionAlertShown = false
        return true
    }

    private func stopCoreAudioTap() {
        removeDefaultOutputListener()
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        ioProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        // 重置 ring index（drainRingAndFFT 与 IOProc 已停，下一次 start 从 0 开始）
        Self.pcmRingReadIndex = 0
        Self.pcmRingWriteIndex = 0
        Self.fftWorkPending = false
    }

    // MARK: - 录音与系统音频权限

    /// Core Audio Process Tap 的权限由系统在 AudioDeviceStart 时处理。
    /// 这里不调用 AVCaptureDevice.requestAccess(for: .audio)，因为那是麦克风权限，
    /// 与“录音与系统音频”不是同一个 TCC 项。系统会在首次启动 tap 时显示正确的授权提示；
    /// 若启动最终失败，再明确引导用户去设置页。
    private func presentSystemAudioPermissionAlert() {
        guard !systemAudioPermissionAlertShown else { return }
        systemAudioPermissionAlertShown = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("audio.permission.title")
        alert.informativeText = t("audio.permission.message")
        alert.addButton(withTitle: t("audio.permission.openSettings"))
        alert.addButton(withTitle: t("cancel"))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemAudioPrivacySettings()
        }
    }

    private func openSystemAudioPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ].compactMap(URL.init(string:))

        for url in urls {
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - 默认输出设备监听

    private func installDefaultOutputListener() {
        guard defaultOutputListenerBlock == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // 经 static sharedRef 拿实例，避免在非隔离回调里直接捕获 self
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                Self.sharedRef?.handleDefaultOutputDeviceChanged()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            Self.deviceListenerQueue, block
        )
        if status == noErr {
            defaultOutputListenerBlock = block
        } else {
            print("[AudioCapture] ❌ install default-output listener failed: OSStatus=\(status)")
        }
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListenerBlock else { return }
        defaultOutputListenerBlock = nil
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            Self.deviceListenerQueue, block
        )
    }

    /// 默认输出变化（主线程，任意队列的 listener 经 Task hop 过来）
    private func handleDefaultOutputDeviceChanged() {
        guard isRunning else { return }
        deviceSwitchDebounceTask?.cancel()
        deviceSwitchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.deviceSwitchDebounceNs)
            guard !Task.isCancelled else { return }
            self?.rebuildTapForDeviceSwitch()
        }
    }

    /// 整体重建 tap，让捕获跟随新的默认输出设备（频谱先归零，新 tap 起来后恢复）
    private func rebuildTapForDeviceSwitch() {
        guard isRunning else { return }
        print("[AudioCapture] 🔄 默认输出设备变化 → 重建 process tap")
        tapGeneration &+= 1
        let gen = tapGeneration
        stopCoreAudioTap()
        isRunning = false
        resetSpectrum()
        Task { await runTapSession(gen: gen) }
    }

    /// IOProc 回调 —— 在 CoreAudio 实时线程被调用
    //
    // ⚠️ 实时线程铁律：不能 malloc、不能 lock、不能 print。
    // 实现：用一个无锁 SPSC 风格的 static ring 缓冲区，IOProc 只做 memcpy + 原子递增 write index。
    // 后台线程定时从 ring 读出做 FFT。
    nonisolated private func handleIOInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard abl.count > 0 else { return }
        let buf = abl[0]
        guard let mData = buf.mData else { return }
        let channels = max(1, Int(buf.mNumberChannels))
        let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        guard totalFloats > 0, channels > 0 else { return }

        let srcPtr = mData.assumingMemoryBound(to: Float.self)
        let frames = totalFloats / channels
        Self.writeToRing(srcPtr: srcPtr, frames: frames, channels: channels)
    }

    /// 无锁 SPSC：IOProc 线程写，FFT 后台线程读
    /// ring 容量 = fftSize * 4 = 8192 floats，足够 ~170ms @ 48kHz
    nonisolated(unsafe) fileprivate static let pcmRing = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    nonisolated(unsafe) fileprivate static let pcmRingCapacity: Int = 8192
    nonisolated(unsafe) fileprivate static var pcmRingWriteIndex: Int = 0  // 仅 IOProc 写
    nonisolated(unsafe) fileprivate static var pcmRingReadIndex: Int = 0   // 仅后台读

    /// IOProc 线程调用：mono 混音 + 写入 ring。完全无分配。
    nonisolated(unsafe) fileprivate static func writeToRing(srcPtr: UnsafePointer<Float>, frames: Int, channels: Int) {
        let cap = pcmRingCapacity
        var w = pcmRingWriteIndex
        if channels == 1 {
            // 单声道快路径：直接拷贝（处理 ring 环绕）
            var remaining = frames
            var srcOffset = 0
            while remaining > 0 {
                let chunk = min(remaining, cap - w)
                memcpy(pcmRing.advanced(by: w), srcPtr.advanced(by: srcOffset), chunk * MemoryLayout<Float>.size)
                w = (w + chunk) % cap
                srcOffset += chunk
                remaining -= chunk
            }
        } else {
            let inv = 1.0 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                let base = i * channels
                for ch in 0..<channels {
                    sum += srcPtr[base + ch]
                }
                pcmRing[w] = sum * inv
                w = (w + 1) % cap
            }
        }
        pcmRingWriteIndex = w

        // 仅当累积达 fftSize 才派发，避免空 dispatch；
        // 用 Bool gate 防止 IOProc 与后台 drainer 并发期间堆积多个 async block
        let r = pcmRingReadIndex
        var avail = w - r
        if avail < 0 { avail += cap }
        if avail >= fftSize && !fftWorkPending {
            fftWorkPending = true
            fftQueue.async {
                fftWorkPending = false
                drainRingAndFFT()
            }
        }
    }

    /// 后台线程：从 ring 读尽可用数据，每 fftSize 触发一次 FFT
    nonisolated(unsafe) fileprivate static func drainRingAndFFT() {
        let cap = pcmRingCapacity
        let w = pcmRingWriteIndex
        var r = pcmRingReadIndex
        var available = w - r
        if available < 0 { available += cap }

        while available >= fftSize {
            // 用 memcpy 处理 ring 环绕，避免每元素模运算
            let firstChunk = min(fftSize, cap - r)
            memcpy(fftChunk, pcmRing.advanced(by: r), firstChunk * MemoryLayout<Float>.size)
            if firstChunk < fftSize {
                memcpy(fftChunk.advanced(by: firstChunk), pcmRing, (fftSize - firstChunk) * MemoryLayout<Float>.size)
            }
            r = (r + fftSize) % cap
            available -= fftSize

            performFFT()
        }
        pcmRingReadIndex = r
    }
}

// MARK: - FFT 处理

extension SystemAudioCaptureService {

    /// 非主线程 FFT 计算（纯数学运算，不涉及 UI）
    /// 输入数据从复用的 `fftChunk` buffer 读取，结果中间数据写入复用 buffer，零堆分配。
    nonisolated(unsafe) fileprivate static func performFFT() {
        guard let setup = fftSetup else { return }
        guard hannWindow.count == fftSize else { return }

        let half = fftSize / 2
        var splitComplex = DSPSplitComplex(realp: fftReal, imagp: fftImag)

        // 加窗：fftWindowed = fftChunk * hannWindow
        hannWindow.withUnsafeBufferPointer { win in
            vDSP_vmul(fftChunk, 1, win.baseAddress!, 1, fftWindowed, 1, vDSP_Length(fftSize))
        }

        // 实数 → split complex
        fftWindowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { cptr in
            vDSP_ctoz(cptr, 2, &splitComplex, 1, vDSP_Length(half))
        }

        vDSP_fft_zrip(setup, &splitComplex, 1, vDSP_Length(fftSizeLog2), FFTDirection(kFFTDirection_Forward))
        vDSP_zvmags(&splitComplex, 1, fftMag, 1, vDSP_Length(half))

        var scalar: Float = 1.0 / Float(fftSize)
        vDSP_vsmul(fftMag, 1, &scalar, fftMag, 1, vDSP_Length(half))

        // dB 映射
        for i in 0..<half {
            let mag = fftMag[i]
            fftDb[i] = mag > 0 ? max(0, min(1, 20 * log10(mag * 10) / 80 + 0.5)) : 0
        }

        // UI 更新节流（~30fps）
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastUIUpdateTime >= uiUpdateIntervalNs else { return }
        lastUIUpdateTime = now

        // 下采样到 16/32/64 频段；只在派发瞬间分配一次（每秒 ≤30 次，可接受）
        let new16 = downsamplePtr(fftDb, srcCount: half, targetCount: 16)
        let new32 = downsamplePtr(fftDb, srcCount: half, targetCount: 32)
        let new64 = downsamplePtr(fftDb, srcCount: half, targetCount: 64)

        DispatchQueue.main.async {
            guard let svc = sharedRef else { return }
            smoothInPlace(into: &svc.spectrum16, from: new16, factor: smoothFactor)
            smoothInPlace(into: &svc.spectrum32, from: new32, factor: smoothFactor)
            smoothInPlace(into: &svc.spectrum64, from: new64, factor: smoothFactor)
            // lastSpectrumNN 维持向后兼容（其它代码可能读取）
            svc.lastSpectrum16 = svc.spectrum16
            svc.lastSpectrum32 = svc.spectrum32
            svc.lastSpectrum64 = svc.spectrum64
            svc.spectrum16Publisher.send(svc.spectrum16)
            svc.spectrum32Publisher.send(svc.spectrum32)
            svc.spectrum64Publisher.send(svc.spectrum64)
            var sum: Float = 0
            for v in svc.spectrum16 { sum += v }
            svc.averageEnergy = sum / Float(svc.spectrum16.count)
        }
    }

    /// 从复用指针下采样到目标频段
    nonisolated private static func downsamplePtr(_ src: UnsafePointer<Float>, srcCount: Int, targetCount: Int) -> [Float] {
        guard targetCount > 0, srcCount >= targetCount else {
            return Array(UnsafeBufferPointer(start: src, count: srcCount))
        }
        var result = [Float](repeating: 0, count: targetCount)
        let binSize = srcCount / targetCount
        let invBin = 1.0 / Float(binSize)
        for i in 0..<targetCount {
            let start = i * binSize
            var sum: Float = 0
            for j in start..<(start + binSize) { sum += src[j] }
            result[i] = sum * invBin
        }
        return result
    }

    /// 原地平滑 `into[i] = into[i] + (from[i] - into[i]) * factor`
    nonisolated private static func smoothInPlace(into dst: inout [Float], from src: [Float], factor: Float) {
        let n = min(dst.count, src.count)
        for i in 0..<n {
            let l = dst[i]
            dst[i] = l + (src[i] - l) * factor
        }
    }
}

// MARK: - 纯 C 风格 IOProc 回调（顶层函数，避免 @MainActor 隔离检查 trap）
private func audioIOProc_C(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    guard abl.count > 0 else { return noErr }
    let buf = abl[0]
    guard let mData = buf.mData else { return noErr }
    let channels = max(1, Int(buf.mNumberChannels))
    let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
    guard totalFloats > 0, channels > 0 else { return noErr }
    let srcPtr = mData.assumingMemoryBound(to: Float.self)
    let frames = totalFloats / channels
    SystemAudioCaptureService.writeToRing(srcPtr: srcPtr, frames: frames, channels: channels)
    return noErr
}
