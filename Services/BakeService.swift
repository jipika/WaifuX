import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct BakeVideoResult: Sendable, Codable {
    let outputURL: URL
    let width: Int
    let height: Int
    let fps: Int
    let duration: TimeInterval
}

/// Scene 壁纸烘焙服务
///
/// 通过启动 wallpaper-wgpu 渲染进程，使用 CoreGraphics 窗口捕获帧，
/// 编码为 H.264 MP4 视频。
///
/// **使用方式：**
/// ```swift
/// let service = BakeService()
/// try await service.bakeVideo(
///     scenePath: "/path/to/scene",
///     outputURL: URL(fileURLWithPath: "/path/to/output.mp4"),
///     progress: { progress in
///         print("烘焙进度: \(Int(progress * 100))%")
///     }
/// )
/// ```
@MainActor
final class BakeService: ObservableObject {
    static let shared = BakeService()
    private static let rendererWrapperBundleIdentifier = "com.waifux.wallpaperwgpu.bake.wrapper"
    private static let minimumCaptureWarmup: TimeInterval = 8.0
    private static let minimumSceneReadyWarmup: TimeInterval = 2.0
    private static let maximumSceneReadyWait: TimeInterval = 24.0
    private static let sceneReadyPollInterval: TimeInterval = 0.25
    private static let sceneReadyStableSampleCount = 6
    private static let sceneReadyStableLumaRange: Double = 3.5
    private static let sceneReadyStableBrightRatioRange: Double = 0.025
    private static let sceneReadyAverageLumaThreshold: Double = 18.0
    private static let sceneReadyBrightRatioThreshold: Double = 0.06
    // --wallpaper 模式下窗口无标题栏，无需裁切
    private static let previewWindowTitlebarHeight = 0

    // MARK: - 发布状态（供 UI 绑定）

    @Published private(set) var isBaking = false
    @Published private(set) var progress: Double = 0  // 0.0 ~ 1.0
    @Published private(set) var statusText = ""

    // MARK: - 烘焙参数

    private struct BakeConfig {
        let scenePath: String
        let assetsPath: String
        let outputURL: URL
        let fps: Int
        let duration: TimeInterval  // 秒
    }

    private struct RendererWrapperBundle {
        let bundleURL: URL
        let executableURL: URL
        let renderedBinaryURL: URL
    }

    // MARK: - 私有状态

    private var renderProcess: Process?
    private var renderPID: pid_t?
    private var rendererIdentities: [OwnedProcessIdentity] = []
    private var retiringRendererIdentities: [Int32: [OwnedProcessIdentity]] = [:]
    private var processTerminationRequested = false
    private var rendererLaunchesInProgress = 0
    private var rendererLaunchExitWaiters: [CheckedContinuation<Void, Never>] = []
    private var isCancelled = false

    private init() {}

    // MARK: - 公开接口

    /// 烘焙 Scene 壁纸为视频
    /// 使用 `--wallpaper --background` 模式启动渲染器，直接铺到桌面层，
    /// 无需辅助功能权限，窗口无标题栏。
    /// - Parameters:
    ///   - scenePath: 壁纸目录或 scene.pkg 路径
    ///   - assetsPath: assets-pc 资源目录路径（nil 时从内嵌 assets 解压）
    ///   - outputURL: 输出 MP4 文件路径
    ///   - targetWidth: 输出视频宽度（nil 时使用主显示器宽度）
    ///   - targetHeight: 输出视频高度（nil 时使用主显示器高度）
    ///   - fps: 视频帧率（默认 30）
    ///   - duration: 视频时长（默认 12 秒）
    ///   - progress: 进度回调（0.0 ~ 1.0，主线程）
    func bakeVideo(
        scenePath: String,
        assetsPath: String? = nil,
        outputURL: URL,
        targetWidth: Int? = nil,
        targetHeight: Int? = nil,
        fps: Int = 30,
        duration: TimeInterval = 12,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> BakeVideoResult {
        if BackgroundRuntimeRole.isRemoteUI {
            var values: [String: Any] = ["path": scenePath, "output": outputURL.absoluteString, "fps": fps, "duration": duration]
            values["assets"] = assetsPath
            values["width"] = targetWidth
            values["height"] = targetHeight
            let result = try await BackgroundRuntimeBridge.requestCodable("bake.video.wait", arguments: BackgroundPropertyList.encode(values), resultKey: "result", as: BakeVideoResult.self)
            progress?(1)
            return result
        }

        guard !processTerminationRequested else { throw CancellationError() }
        guard !isBaking else { throw BakeError.alreadyBaking }
        defer {
            if let process = renderProcess, process.isRunning {
                process.terminate()
                let identity = OwnedProcessIdentity.capture(process.processIdentifier)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    identity?.signal(SIGKILL)
                }
            }
            if renderProcess == nil, let pid = renderPID {
                terminateRenderer(pid: pid)
            }
            isBaking = false
            self.progress = 0
            statusText = ""
            isCancelled = false
            renderProcess = nil
            renderPID = nil
            rendererIdentities.removeAll()
        }

        isBaking = true
        isCancelled = false
        self.progress = 0
        progress?(0)
        statusText = "准备中..."

        // 1. 解析 assets 路径
        let resolvedAssets: String
        if let ap = assetsPath, !ap.isEmpty {
            resolvedAssets = ap
            print("[BakeService] 使用外部 assets: \(resolvedAssets)")
        } else if let embedded = await WallpaperEngineEmbeddedAssets.awaitAssetsReady() {
            resolvedAssets = embedded
            print("[BakeService] 使用内嵌 assets: \(resolvedAssets)")
        } else {
            resolvedAssets = ""
            print("[BakeService] ⚠️ assets 为空，未传入 --assets 参数")
        }
        try checkCanContinueBaking()

        // 2. 检查屏幕录制权限（--wallpaper 模式下渲染器直接铺到桌面层，无需辅助功能）
        statusText = "检查屏幕录制权限..."
        if !checkScreenCapturePermission() {
            let granted = await requestScreenCapturePermission()
            try checkCanContinueBaking()
            guard granted else {
                print("[BakeService] ❌ 屏幕录制权限被拒绝")
                isBaking = false
                throw BakeError.screenCaptureDenied
            }
        }
        print("[BakeService] ✅ 屏幕录制权限已授予")
        self.progress = 0.02
        statusText = "正在启动渲染器..."
        progress?(0.02)

        // 3. 启动 wallpaper-wgpu（--wallpaper --background 铺到桌面层，无需 AX/CGS 调整窗口）
        guard let cliURL = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
            print("[BakeService] ❌ wallpaper-wgpu 二进制未找到")
            throw BakeError.cliNotFound
        }
        print("[BakeService] wallpaper-wgpu 路径: \(cliURL.path)")

        // 参数格式: --release -- <path> --assets <assets> --wallpaper --background
        var args = ["--release", "--", scenePath]
        if !resolvedAssets.isEmpty {
            args += ["--assets", resolvedAssets]
        }
        args += ["--wallpaper", "--background"]

        print("[BakeService] 启动命令: \(cliURL.lastPathComponent) \(args.joined(separator: " "))")

        let launchedPID: pid_t
        do {
            let wrapper = try Self.prepareRendererWrapper(for: cliURL)
            launchedPID = try await launchRendererWrapper(wrapper, arguments: args)
            renderPID = launchedPID
            try checkCanContinueBaking()
            statusText = "等待渲染窗口..."
            self.progress = 0.05
            progress?(0.05)
            print("[BakeService] ✅ wallpaper-wgpu wrapper 已启动 (pid=\(launchedPID))")
        } catch {
            print("[BakeService] ❌ 启动 wallpaper-wgpu 失败: \(error.localizedDescription)")
            isBaking = false
            throw BakeError.executionFailed(
                "启动 wallpaper-wgpu 失败: \(WallpaperEngineError.userFacingLaunchFailure(error))"
            )
        }

        // 4. 等待桌面层窗口出现（--wallpaper 已铺满显示器，无需移动/缩放）
        let windowInfo = try await waitForWindow(pid: launchedPID, timeout: 10)
        let windowID = windowInfo.windowID

        print("[BakeService] 找到桌面层渲染窗口 ID=\(windowID) bounds=\(windowInfo.width)x\(windowInfo.height)")
        self.progress = 0.10
        statusText = "等待画面稳定..."
        progress?(0.10)

        // 5. 使用主显示器分辨率作为烘焙尺寸。桌面层窗口已覆盖整个显示器，无标题栏。
        guard let mainScreen = NSScreen.main ?? NSScreen.screens.first else {
            throw BakeError.windowPlacementFailed("未找到可用显示器")
        }
        let screenFrame = mainScreen.frame
        let bakeWidth = Self.evenEncodeDimension(targetWidth ?? Int(screenFrame.width))
        let bakeHeight = Self.evenEncodeDimension(targetHeight ?? Int(screenFrame.height))
        // --wallpaper 无标题栏，捕获尺寸 = 编码尺寸
        let preparedWidth = bakeWidth
        let preparedHeight = bakeHeight

        print("[BakeService] --wallpaper 桌面层烘焙: 窗口=\(Int(screenFrame.width))x\(Int(screenFrame.height)) 输出=\(bakeWidth)x\(bakeHeight)")

        statusText = "等待画面稳定..."
        let firstReadyFrame = try await waitForSceneReady(
            windowID: windowID,
            captureWidth: preparedWidth,
            captureHeight: preparedHeight
        )

        self.progress = 0.15
        statusText = "正在烘焙..."
        progress?(0.15)

        // 6. 开始捕获和编码
        let result = try await captureAndEncode(
            windowID: windowID,
            initialFrame: firstReadyFrame,
            fps: fps,
            duration: duration,
            outputURL: outputURL,
            targetWidth: bakeWidth,
            targetHeight: bakeHeight,
            captureWidth: preparedWidth,
            captureHeight: preparedHeight,
            scenePath: scenePath,
            progress: progress
        )

        // 7. 完成
        statusText = "完成"
        self.progress = 1.0
        progress?(1.0)
        return result
    }

    /// 取消烘焙
    func cancel() {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("bake.cancel"); return }
        isCancelled = true
        statusText = "已取消"
        if let process = renderProcess {
            process.terminate()
            // watchdog
            let identity = OwnedProcessIdentity.capture(process.processIdentifier)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                identity?.signal(SIGKILL)
            }
        }
        if renderProcess == nil, let pid = renderPID {
            terminateRenderer(pid: pid)
        }
        renderProcess = nil
        renderPID = nil
        rendererIdentities.removeAll()
        isBaking = false
        progress = 0
    }

    /// Final process teardown cannot rely on a watchdog that runs after the
    /// Helper has exited. The NSWorkspace wrapper is owned by launchd and is
    /// therefore not included in the Helper's ordinary descendant snapshot.
    func prepareForProcessTermination() {
        guard BackgroundRuntimeRole.isHelper else { return }
        processTerminationRequested = true
        isCancelled = true
        let allIdentities = rendererIdentities + retiringRendererIdentities.values.flatMap { $0 }
        var visited = Set<Int32>()
        for identity in allIdentities where !visited.contains(identity.pid) && identity.stillMatches() {
            visited.insert(identity.pid)
            let children = BackgroundChildProcessCleanup.snapshot(rootPID: identity.pid)
            BackgroundChildProcessCleanup.terminate(children)
            identity.signal(SIGKILL)
        }
        if let process = renderProcess, process.isRunning,
           let identity = OwnedProcessIdentity.capture(process.processIdentifier) {
            identity.signal(SIGKILL)
        }
        renderProcess = nil
        renderPID = nil
        rendererIdentities.removeAll()
        retiringRendererIdentities.removeAll()
        isBaking = false
        progress = 0
        statusText = "已取消"
    }

    /// LaunchServices owns wrapper processes, so a pending launch must finish
    /// reporting its PID before the Helper can leave. UI quit still has its
    /// existing deadline and retains the UI if the Helper cannot finish.
    func finishPendingRendererLaunchesForProcessTermination() async {
        guard BackgroundRuntimeRole.isHelper else { return }
        if rendererLaunchesInProgress > 0 {
            await withCheckedContinuation { rendererLaunchExitWaiters.append($0) }
        }
        prepareForProcessTermination()
    }

    private func checkCanContinueBaking() throws {
        try Task.checkCancellation()
        guard !isCancelled, !processTerminationRequested else { throw CancellationError() }
    }

    #if DEBUG
    /// Exercise the production LaunchServices path without a real wallpaper or
    /// screen recording permission. Available only to the isolated Helper job.
    func regressionLaunchWrapperForProcessTermination(executableURL: URL,
                                                      arguments: [String]) async throws -> Int32 {
        guard BackgroundRuntimeRole.isIsolatedTest, !processTerminationRequested else {
            throw CocoaError(.featureUnsupported)
        }
        let wrapper = try Self.prepareRendererWrapper(for: executableURL)
        let pid = try await launchRendererWrapper(wrapper, arguments: arguments)
        renderPID = pid
        return pid
    }
    #endif

    // MARK: - 窗口查找

    /// 等待 wallpaper-wgpu 创建窗口并返回窗口信息
    private func waitForWindow(pid: pid_t, timeout: TimeInterval) async throws -> (windowID: CGWindowID, width: Int, height: Int) {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.3
        var fallbackInfo: (windowID: CGWindowID, width: Int, height: Int)?

        while !isCancelled, Date().timeIntervalSince(startTime) < timeout {
            if let info = findWindowForProcess(pid: pid, preferNamedRendererWindow: true) {
                return info
            }
            if fallbackInfo == nil {
                fallbackInfo = findWindowForProcess(pid: pid, preferNamedRendererWindow: false)
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        if isCancelled {
            throw BakeError.cancelled
        }
        if let fallbackInfo {
            print("[BakeService] ⚠️ 未等到命名预览窗口，使用 renderer 进程最大候选窗口")
            return fallbackInfo
        }
        throw BakeError.windowNotFound
    }

    /// 使用 CoreGraphics 查找指定进程的窗口
    private func findWindowForProcess(
        pid: pid_t,
        preferNamedRendererWindow: Bool
    ) -> (windowID: CGWindowID, width: Int, height: Int)? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let screens = NSScreen.screens
        let desktopFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
        let mainFrame = NSScreen.main?.frame ?? screens.first?.frame ?? .zero
        var candidates: [(windowID: CGWindowID, width: Int, height: Int, score: CGFloat, bounds: CGRect)] = []

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int, ownerPID == pid else { continue }
            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let windowName = (window[kCGWindowName as String] as? String ?? "").lowercased()
            let ownerName = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let isNamedRendererWindow = windowName.contains("wallpaper-wgpu")
            if preferNamedRendererWindow, !isNamedRendererWindow {
                continue
            }

            let rect = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let normalizedRect = normalizedWindowBounds(rect, screens: screens, desktopFrame: desktopFrame)
            let width = Int(normalizedRect.width)
            let height = Int(normalizedRect.height)
            guard width > 0, height > 0 else { continue }

            // 跳过太小的窗口（避免找到进程的其他 UI 元素）
            guard width >= 100, height >= 100 else { continue }

            let overlap = normalizedRect.intersection(mainFrame)
            let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
            let sizeDelta = abs(normalizedRect.width - mainFrame.width) + abs(normalizedRect.height - mainFrame.height)
            var score = overlapArea - sizeDelta * 32
            if isNamedRendererWindow {
                score += mainFrame.width * mainFrame.height
            }
            if ownerName.contains("wallpaperwgpu") {
                score += mainFrame.width * mainFrame.height * 0.25
            }
            candidates.append((windowID, width, height, score, normalizedRect))
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        if candidates.count > 1 {
            let summary = candidates
                .sorted { $0.score > $1.score }
                .prefix(4)
                .map { "#\($0.windowID) \(Int($0.bounds.width))x\(Int($0.bounds.height))@\(Int($0.bounds.origin.x)),\(Int($0.bounds.origin.y)) score=\(Int($0.score))" }
                .joined(separator: " | ")
            print("[BakeService] 多窗口候选，选择主屏匹配窗口: \(summary)")
        }
        return (best.windowID, best.width, best.height)
    }

    private func normalizedWindowBounds(_ bounds: CGRect, screens: [NSScreen], desktopFrame: CGRect) -> CGRect {
        guard !desktopFrame.isNull else { return bounds }
        let flippedBounds = CGRect(
            x: bounds.origin.x,
            y: desktopFrame.maxY - bounds.origin.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )

        func totalIntersectionArea(for candidate: CGRect) -> CGFloat {
            screens.reduce(CGFloat.zero) { total, screen in
                let intersection = candidate.intersection(screen.frame)
                guard !intersection.isNull, !intersection.isEmpty else { return total }
                return total + intersection.width * intersection.height
            }
        }

        return totalIntersectionArea(for: flippedBounds) > totalIntersectionArea(for: bounds) ? flippedBounds : bounds
    }

    private func preparePreviewWindowForBake(
        pid: pid_t,
        windowID: CGWindowID,
        targetWidth: Int,
        targetHeight: Int
    ) async throws -> CGRect {
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        let offscreenOrigin = Self.offscreenPreviewOrigin(for: targetSize)
        let placedByAX = setWindowFrameUsingAccessibility(
            pid: pid,
            windowID: windowID,
            origin: offscreenOrigin,
            size: targetSize
        )
        let placedByCGS = placedByAX ? false : setWindowFrameUsingCGS(
            windowID: windowID,
            origin: offscreenOrigin,
            size: targetSize,
            pid: pid
        )

        guard placedByCGS || placedByAX else {
            throw BakeError.windowPlacementFailed("无法移动/缩放 wallpaper-wgpu 预览窗口。请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 WaifuX，然后重试烘焙。")
        }

        if let bounds = try await waitForWindowPlacement(
            windowID: windowID,
            targetOrigin: offscreenOrigin,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        ) {
            print("[BakeService] 预览窗口已准备: \(Int(bounds.width))x\(Int(bounds.height))@\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) via \(placedByAX ? "AX" : "CGS")")
            try await Task.sleep(nanoseconds: 500_000_000)
            return bounds
        } else if placedByCGS,
                  setWindowFrameUsingAccessibility(pid: pid, windowID: windowID, origin: offscreenOrigin, size: targetSize),
                  let bounds = try await waitForWindowPlacement(
                    windowID: windowID,
                    targetOrigin: offscreenOrigin,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight
                  ) {
            print("[BakeService] 预览窗口已准备: \(Int(bounds.width))x\(Int(bounds.height))@\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) via AX retry")
            try await Task.sleep(nanoseconds: 500_000_000)
            return bounds
        } else if let bounds = windowBounds(windowID: windowID) {
            throw BakeError.windowPlacementFailed("预览窗口尺寸未能调整到烘焙目标 \(targetWidth)x\(targetHeight)，当前为 \(Int(bounds.width))x\(Int(bounds.height))。请确认已授予辅助功能权限后重试。")
        } else {
            throw BakeError.windowPlacementFailed("无法读取 wallpaper-wgpu 预览窗口尺寸，请重试烘焙。")
        }
    }

    private static func offscreenPreviewOrigin(for size: CGSize) -> CGPoint {
        let displays = activeDisplayUnionBounds()
        return CGPoint(
            x: displays.maxX + 128,
            y: max(displays.minY, 0) + 64
        )
    }

    private static func activeDisplayUnionBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else {
            return NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).reduce(CGRect.null) { partial, displayID in
            partial.union(CGDisplayBounds(displayID))
        }
    }

    private func setWindowFrameUsingCGS(windowID: CGWindowID, origin: CGPoint, size: CGSize, pid: pid_t) -> Bool {
        guard CGSMoveWindowFunc != nil,
              CGSSetWindowShapeFn != nil else {
            return false
        }
        guard let cgsWindow = findCGSWindowID(windowID, ownerPID: pid) else { return false }
        CGSMoveWindow(cgsWindow, origin)
        CGSResizeWindow(cgsWindow, size)
        return true
    }

    private func setWindowFrameUsingAccessibility(
        pid: pid_t,
        windowID: CGWindowID,
        origin: CGPoint,
        size: CGSize
    ) -> Bool {
        guard accessibilityIsTrusted(prompt: true) else {
            print("[BakeService] ⚠️ 辅助功能权限未授权，无法通过 AX 调整 renderer 预览窗口")
            return false
        }

        guard let window = accessibilityWindow(pid: pid, windowID: windowID) else {
            print("[BakeService] ⚠️ 未找到 renderer 的 AX 窗口")
            return false
        }

        var position = origin
        var targetSize = size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
            return false
        }

        let moveError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if moveError != .success || sizeError != .success {
            print("[BakeService] ⚠️ AX 调整窗口失败 move=\(moveError.rawValue) size=\(sizeError.rawValue)")
            return false
        }
        return true
    }

    private func accessibilityWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success,
              let windows = value as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        if let matching = windows.first(where: { accessibilityWindowNumber($0) == Int(windowID) }) {
            return matching
        }
        return windows.count == 1 ? windows[0] : nil
    }

    private func accessibilityWindowNumber(_ window: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value)
        guard error == .success else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let intValue = value as? Int { return intValue }
        return nil
    }

    private func accessibilityIsTrusted(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func waitForWindowPlacement(
        windowID: CGWindowID,
        targetOrigin: CGPoint,
        targetWidth: Int,
        targetHeight: Int,
        timeout: TimeInterval = 3.0
    ) async throws -> CGRect? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let bounds = windowBounds(windowID: windowID) {
                let widthDelta = abs(Int(bounds.width.rounded()) - targetWidth)
                let heightDelta = abs(Int(bounds.height.rounded()) - targetHeight)
                let originXDelta = abs(bounds.origin.x - targetOrigin.x)
                let originYDelta = abs(bounds.origin.y - targetOrigin.y)
                if widthDelta <= 4,
                   heightDelta <= 4,
                   originXDelta <= 8,
                   originYDelta <= 8,
                   Self.windowIsOutsideActiveDisplays(bounds) {
                    return bounds
                }
            }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        return nil
    }

    private static func windowIsOutsideActiveDisplays(_ bounds: CGRect) -> Bool {
        let displays = activeDisplayUnionBounds()
        guard !displays.isNull, !displays.isEmpty else { return true }
        let overlap = bounds.intersection(displays)
        return overlap.isNull || overlap.isEmpty
    }

    private func windowBounds(windowID: CGWindowID) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windowList {
            guard let number = window[kCGWindowNumber as String] as? CGWindowID,
                  number == windowID,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            return CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
        }
        return nil
    }

    // MARK: - 帧捕获和编码

    private func captureAndEncode(
        windowID: CGWindowID,
        initialFrame: CGImage? = nil,
        fps: Int,
        duration: TimeInterval,
        outputURL: URL,
        targetWidth: Int? = nil,
        targetHeight: Int? = nil,
        captureWidth: Int? = nil,
        captureHeight: Int? = nil,
        scenePath: String? = nil,  // 用于烘焙时缓存静态帧
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> BakeVideoResult {
        let totalFrames = max(1, Int(Double(fps) * duration))
        let frameCaptureWidth = max(1, captureWidth ?? targetWidth ?? 0)
        let frameCaptureHeight = max(1, captureHeight ?? targetHeight ?? 0)
        let firstFrame: CGImage
        if let initialFrame {
            firstFrame = initialFrame
        } else {
            firstFrame = try await captureInitialFrameForEncoding(
                windowID: windowID,
                captureWidth: frameCaptureWidth,
                captureHeight: frameCaptureHeight
            )
        }
        let outputWidth = Self.evenEncodeDimension(targetWidth ?? firstFrame.width)
        let outputHeight = Self.evenEncodeDimension(targetHeight ?? firstFrame.height)
        let sourceCropRect = contentCropRectForEncoding(
            for: firstFrame,
            targetWidth: outputWidth,
            targetHeight: outputHeight
        )

        print("[BakeService] 捕获尺寸 \(firstFrame.width)x\(firstFrame.height) (SCK nominalResolution)，编码尺寸 \(outputWidth)x\(outputHeight)")
        if let sourceCropRect {
            print("[BakeService] 裁剪捕获源区域 \(Int(sourceCropRect.width))x\(Int(sourceCropRect.height))@\(Int(sourceCropRect.origin.x)),\(Int(sourceCropRect.origin.y)) 后编码")
        }
        if firstFrame.width != outputWidth || firstFrame.height != outputHeight {
            print("[BakeService] 捕获窗口尺寸与编码目标不一致，将等比填充缩放，避免多屏超大窗口直接编码")
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        Self.removeStaleEncodeTempFiles(for: outputURL)
        let encodeURL = Self.temporaryEncodeURL(for: outputURL)
        try? FileManager.default.removeItem(at: encodeURL)

        // AVAssetWriter 设置（视频 + 静音音频轨）
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: outputWidth * outputHeight * 3,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ] as [String: Any]
        ]

        let writer = try AVAssetWriter(outputURL: encodeURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(videoInput) else {
            throw BakeError.writerFailed("无法添加视频输入")
        }
        writer.add(videoInput)

        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: encodeURL)
            throw BakeError.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        writer.startSession(atSourceTime: .zero)
        var writerCompleted = false
        var outputCommitted = false
        defer {
            if !writerCompleted {
                videoInput.markAsFinished()
                writer.cancelWriting()
            }
            if !outputCommitted {
                try? FileManager.default.removeItem(at: encodeURL)
            }
        }

        // 静态帧缓存 key（用于锁屏/fallback），同一 scenePath 只存一次
        let staticFrameCacheKey: String? = scenePath.map { path in
            let hash = abs(path.hashValue)
            return "baked_frame_\(hash)"
        }
        var staticFrameSaved = false

        let captureStart = Date()
        let frameInterval = 1.0 / Double(fps)
        var frameIndex = 0
        var lastFrameImage: CGImage?
        var lastPresentationTime = CMTime.zero

        // 帧循环按真实时间采样：如果 4K 捕获/编码跑不满 30fps，保留真实 PTS，
        // 不把更长的真实渲染时长硬塞进固定帧数，避免成片加速。
        while true {
            if isCancelled {
                throw BakeError.cancelled
            }

            let targetElapsed = Double(frameIndex) * frameInterval
            if targetElapsed >= duration { break }

            let elapsedBeforeSleep = Date().timeIntervalSince(captureStart)
            if targetElapsed > elapsedBeforeSleep {
                try await Task.sleep(nanoseconds: UInt64((targetElapsed - elapsedBeforeSleep) * 1_000_000_000))
            }

            let sampleElapsed = Date().timeIntervalSince(captureStart)
            if frameIndex > 0, sampleElapsed >= duration { break }

            let frameImage: CGImage
            if frameIndex == 0 {
                frameImage = firstFrame
            } else {
                // 捕获帧
                var captured = await captureWindowFrame(
                    windowID: windowID,
                    captureWidth: frameCaptureWidth,
                    captureHeight: frameCaptureHeight
                )
                if captured == nil {
                    // 捕获失败不立即中断，重试
                    print("[BakeService] 帧 \(frameIndex) 捕获失败，重试...")
                    try await Task.sleep(nanoseconds: UInt64(frameInterval * 0.5 * 1_000_000_000))
                    captured = await captureWindowFrame(
                        windowID: windowID,
                        captureWidth: frameCaptureWidth,
                        captureHeight: frameCaptureHeight
                    )
                    guard captured != nil else {
                        throw BakeError.captureFailed("帧 \(frameIndex) 捕获失败")
                    }
                }
                frameImage = captured!
            }
            lastFrameImage = frameImage

            // 保存第一帧非黑帧作为静态 fallback（每次烘焙都覆盖更新，确保重新烘焙后封面和锁屏图同步）
            if !staticFrameSaved, let key = staticFrameCacheKey, isNonBlackFrame(frameImage) {
                saveStaticFrame(frameImage, cacheKey: key)
                staticFrameSaved = true
                print("[BakeService] ✅ 静态 fallback 帧已更新 (key=\(key))")
            }

            let presentationTime: CMTime
            if frameIndex == 0 {
                presentationTime = .zero
            } else {
                presentationTime = CMTime(
                    seconds: sampleElapsed,
                    preferredTimescale: CMTimeScale(max(fps * 1000, 600))
                )
            }
            lastPresentationTime = presentationTime

            try autoreleasepool {
                try appendFrame(
                    adaptor: adaptor,
                    input: videoInput,
                    writer: writer,
                    cgImage: frameImage,
                    sourceCropRect: sourceCropRect,
                    targetWidth: outputWidth,
                    targetHeight: outputHeight,
                    at: presentationTime
                )
            }

            // 更新进度
            let currentProgress = min(1.0, max(Double(frameIndex + 1) / Double(totalFrames), sampleElapsed / duration))
            self.progress = currentProgress
            self.statusText = "烘焙中 \(Int(currentProgress * 100))%"
            progress?(currentProgress)
            frameIndex += 1
        }

        if let lastFrameImage,
           CMTimeCompare(lastPresentationTime, CMTime(seconds: duration, preferredTimescale: CMTimeScale(max(fps * 1000, 600)))) < 0 {
            try autoreleasepool {
                try appendFrame(
                    adaptor: adaptor,
                    input: videoInput,
                    writer: writer,
                    cgImage: lastFrameImage,
                    sourceCropRect: sourceCropRect,
                    targetWidth: outputWidth,
                    targetHeight: outputHeight,
                    at: CMTime(seconds: duration, preferredTimescale: CMTimeScale(max(fps * 1000, 600)))
                )
            }
        }

        // 完成写入
        videoInput.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) let w = writer
            w.finishWriting {
                if w.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BakeError.writerFailed(w.error?.localizedDescription ?? "finishWriting 失败"))
                }
            }
        }
        writerCompleted = true

        guard await Self.isEncodedVideoUsable(at: encodeURL, minimumDuration: min(duration, 0.5)) else {
            throw BakeError.writerFailed("finishWriting 完成但 MP4 产物不可播放")
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: encodeURL, to: outputURL)
        outputCommitted = true

        // 终止渲染进程
        if let process = renderProcess {
            process.terminate()
        } else if let pid = renderPID {
            terminateRenderer(pid: pid)
        }
        renderProcess = nil
        renderPID = nil

        return BakeVideoResult(
            outputURL: outputURL,
            width: outputWidth,
            height: outputHeight,
            fps: fps,
            duration: duration
        )
    }

    private static func temporaryEncodeURL(for outputURL: URL) -> URL {
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        return outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(baseName).\(UUID().uuidString).writing.mp4")
    }

    private static func removeStaleEncodeTempFiles(for outputURL: URL) {
        let directory = outputURL.deletingLastPathComponent()
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".\(baseName)."), name.hasSuffix(".writing.mp4") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func isEncodedVideoUsable(at url: URL, minimumDuration: TimeInterval) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 10_000 else {
            return false
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration >= minimumDuration else { return false }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return !tracks.isEmpty
        } catch {
            return false
        }
    }

    /// 优先使用 ScreenCaptureKit 捕获单窗口完整帧；CoreGraphics 只保留为兜底。
    private func captureWindowFrame(
        windowID: CGWindowID,
        captureWidth: Int,
        captureHeight: Int
    ) async -> CGImage? {
        if let image = try? await captureWindowFrameWithScreenCaptureKit(
            windowID: windowID,
            width: captureWidth,
            height: captureHeight
        ) {
            return image
        }
        return captureWindowFrameWithCoreGraphics(windowID: windowID)
    }

    private func captureWindowFrameWithScreenCaptureKit(
        windowID: CGWindowID,
        width: Int,
        height: Int
    ) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw BakeError.captureFailed("ScreenCaptureKit 未找到窗口 \(windowID)")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.captureResolution = .nominal

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? BakeError.captureFailed("ScreenCaptureKit 返回空帧"))
                }
            }
        }
    }

    /// 使用 CoreGraphics 捕获窗口帧，仅作为 ScreenCaptureKit 不可用时的 fallback。
    private func captureWindowFrameWithCoreGraphics(windowID: CGWindowID) -> CGImage? {
        // Metal/winit 窗口在多显示器或 Retina 环境下使用 .bestResolution 时，
        // CoreGraphics 可能返回 2x 画布但只填充逻辑尺寸内容，导致成片只占左上 1/4。
        // 先按 nominalResolution 捕获完整逻辑画面，再交给编码路径缩放到目标像素尺寸。
        CGWindowListCreateImage(
            .infinite,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    private static func evenEncodeDimension(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }

    private struct FrameBrightnessMetrics {
        let averageLuma: Double
        let brightPixelRatio: Double

        var readinessScore: Double {
            averageLuma + brightPixelRatio * 255.0
        }
    }

    private func captureInitialFrameForEncoding(
        windowID: CGWindowID,
        captureWidth: Int,
        captureHeight: Int
    ) async throws -> CGImage {
        try await waitForSceneReady(
            windowID: windowID,
            captureWidth: captureWidth,
            captureHeight: captureHeight
        )
    }

    private func waitForSceneReady(
        windowID: CGWindowID,
        captureWidth: Int,
        captureHeight: Int
    ) async throws -> CGImage {
        let startTime = Date()
        var lastFrame: CGImage?
        var bestFrame: CGImage?
        var bestMetrics: FrameBrightnessMetrics?
        var stableMetrics: [FrameBrightnessMetrics] = []

        print("[BakeService] 等待画面亮度稳定后开始烘焙，最多等待 \(Self.maximumSceneReadyWait)s")

        while !isCancelled, Date().timeIntervalSince(startTime) < Self.maximumSceneReadyWait {
            if let image = await captureWindowFrame(
                windowID: windowID,
                captureWidth: captureWidth,
                captureHeight: captureHeight
            ),
               let metrics = frameBrightnessMetrics(image) {
                lastFrame = image
                if bestMetrics == nil || metrics.readinessScore > bestMetrics!.readinessScore {
                    bestMetrics = metrics
                    bestFrame = image
                }

                let elapsed = Date().timeIntervalSince(startTime)
                let litEnough = isRenderableFrame(metrics)
                if elapsed >= Self.minimumSceneReadyWarmup, litEnough {
                    stableMetrics.append(metrics)
                    if stableMetrics.count > Self.sceneReadyStableSampleCount {
                        stableMetrics.removeFirst(stableMetrics.count - Self.sceneReadyStableSampleCount)
                    }
                    if stableMetrics.count >= Self.sceneReadyStableSampleCount,
                       isBrightnessStable(stableMetrics) {
                        print(
                            "[BakeService] ✅ 画面已稳定 avgLuma=\(String(format: "%.1f", metrics.averageLuma)) brightRatio=\(String(format: "%.3f", metrics.brightPixelRatio)) elapsed=\(String(format: "%.1f", elapsed))s"
                        )
                        return image
                    }
                } else {
                    stableMetrics.removeAll(keepingCapacity: true)
                }
            }

            try await Task.sleep(nanoseconds: UInt64(Self.sceneReadyPollInterval * 1_000_000_000))
        }

        if isCancelled {
            throw BakeError.cancelled
        }
        if let bestFrame, let bestMetrics {
            print(
                "[BakeService] ⚠️ 等待画面稳定超时，使用最亮帧开始编码 avgLuma=\(String(format: "%.1f", bestMetrics.averageLuma)) brightRatio=\(String(format: "%.3f", bestMetrics.brightPixelRatio))"
            )
            return bestFrame
        }
        if let lastFrame {
            print("[BakeService] ⚠️ 等待画面稳定超时，使用最后捕获帧开始编码")
            return lastFrame
        }
        throw BakeError.captureFailed("无法捕获首帧")
    }

    private func isRenderableFrame(_ metrics: FrameBrightnessMetrics) -> Bool {
        metrics.averageLuma >= Self.sceneReadyAverageLumaThreshold
            || metrics.brightPixelRatio >= Self.sceneReadyBrightRatioThreshold
    }

    private func isBrightnessStable(_ metrics: [FrameBrightnessMetrics]) -> Bool {
        guard metrics.count >= Self.sceneReadyStableSampleCount else { return false }
        let lumas = metrics.map(\.averageLuma)
        let brightRatios = metrics.map(\.brightPixelRatio)
        guard let minLuma = lumas.min(),
              let maxLuma = lumas.max(),
              let minBrightRatio = brightRatios.min(),
              let maxBrightRatio = brightRatios.max() else {
            return false
        }
        return (maxLuma - minLuma) <= Self.sceneReadyStableLumaRange
            && (maxBrightRatio - minBrightRatio) <= Self.sceneReadyStableBrightRatioRange
    }

    private func contentCropRectForEncoding(
        for image: CGImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> CGRect? {
        if let chromeCropRect = windowChromeContentCropRectIfNeeded(
            for: image,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        ) {
            return chromeCropRect
        }
        return blackBorderContentCropRectIfNeeded(
            for: image,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
    }

    private func windowChromeContentCropRectIfNeeded(
        for image: CGImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> CGRect? {
        guard image.width >= targetWidth,
              image.height >= targetHeight else {
            return nil
        }

        let verticalExtra = image.height - targetHeight
        let horizontalExtra = image.width - targetWidth
        if (16...96).contains(verticalExtra) {
            return CGRect(
                x: max(0, horizontalExtra / 2),
                y: verticalExtra,
                width: targetWidth,
                height: targetHeight
            )
        }

        guard let detectedTopInset = detectWindowChromeTopInset(in: image),
              detectedTopInset > 0 else {
            return nil
        }
        let availableHeight = image.height - detectedTopInset
        guard availableHeight >= 240 else {
            return nil
        }
        return CGRect(
            x: max(0, horizontalExtra / 2),
            y: detectedTopInset,
            width: min(targetWidth, image.width),
            height: min(targetHeight, availableHeight)
        )
    }

    private func detectWindowChromeTopInset(in image: CGImage) -> Int? {
        guard image.width >= 64, image.height >= 64 else { return nil }
        let maxScanY = min(96, image.height - 1)
        var bestInset: Int?
        var strongestDrop = 0.0
        var previousLuma: Double?

        for y in 0...maxScanY {
            guard let metrics = rowBrightnessMetrics(in: image, y: y) else { continue }
            if let previousLuma {
                let drop = previousLuma - metrics.averageLuma
                if y >= 20,
                   drop > strongestDrop,
                   drop >= 14.0,
                   metrics.darkPixelRatio >= 0.10 {
                    strongestDrop = drop
                    bestInset = y
                }
            }
            previousLuma = metrics.averageLuma
        }

        return bestInset
    }

    private func rowBrightnessMetrics(in image: CGImage, y: Int) -> (averageLuma: Double, darkPixelRatio: Double)? {
        let sampleWidth = min(256, image.width)
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        let cropRect = CGRect(x: 0, y: y, width: image.width, height: 1)
        guard let cropped = image.cropping(to: cropRect) else { return nil }

        var pixels = [UInt8](repeating: 0, count: bytesPerRow)
        let drewImage = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: sampleWidth,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleWidth, height: 1))
            return true
        }
        guard drewImage else { return nil }

        var totalLuma = 0.0
        var darkPixels = 0
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let b = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let r = Double(pixels[index + 2])
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            totalLuma += luma
            if luma < 220.0 {
                darkPixels += 1
            }
        }

        return (
            averageLuma: totalLuma / Double(sampleWidth),
            darkPixelRatio: Double(darkPixels) / Double(sampleWidth)
        )
    }

    private func blackBorderContentCropRectIfNeeded(
        for image: CGImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> CGRect? {
        guard image.width >= 2, image.height >= 2 else {
            return nil
        }

        let targetAspect = CGFloat(targetWidth) / CGFloat(max(1, targetHeight))
        var bestRect: CGRect?
        var bestArea: CGFloat = 0

        let candidates = [
            CGRect(x: 0, y: 0, width: image.width / 2, height: image.height / 2),
            CGRect(x: 0, y: 0, width: image.width / 2, height: image.height),
            CGRect(x: 0, y: 0, width: image.width, height: image.height / 2)
        ]

        for rect in candidates {
            let cropAspect = rect.width / max(1, rect.height)
            guard abs(cropAspect - targetAspect) <= 0.08 else { continue }
            guard let insideLuma = averageLuma(in: image, rect: rect), insideLuma >= 8.0 else { continue }

            let outsideRects = remainingRects(inside: rect, imageWidth: image.width, imageHeight: image.height)
            let outsideMax = outsideRects
                .compactMap { averageLuma(in: image, rect: $0) }
                .max() ?? 0
            guard outsideMax <= max(4.0, insideLuma * 0.18) else { continue }

            let area = rect.width * rect.height
            if area > bestArea {
                bestArea = area
                bestRect = rect
            }
        }

        return bestRect
    }

    private func remainingRects(inside rect: CGRect, imageWidth: Int, imageHeight: Int) -> [CGRect] {
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        guard bounds.contains(rect) else { return [] }

        return [
            CGRect(x: 0, y: 0, width: rect.minX, height: bounds.height),
            CGRect(x: rect.maxX, y: 0, width: bounds.maxX - rect.maxX, height: bounds.height),
            CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.minY),
            CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: bounds.maxY - rect.maxY)
        ].filter { $0.width >= 1 && $0.height >= 1 }
    }

    private func averageLuma(in image: CGImage, rect: CGRect) -> Double? {
        let integralRect = rect.integral
        guard integralRect.width >= 1,
              integralRect.height >= 1,
              let cropped = image.cropping(to: integralRect) else {
            return nil
        }

        let sampleSize = 24
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleSize * bytesPerRow)
        let drewImage = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: sampleSize,
                    height: sampleSize,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        guard drewImage else { return nil }

        var totalLuma = 0.0
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let b = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let r = Double(pixels[index + 2])
            totalLuma += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return totalLuma / Double(sampleSize * sampleSize)
    }

    /// 判断帧是否为非黑的有效帧
    private func isNonBlackFrame(_ image: CGImage) -> Bool {
        guard let metrics = frameBrightnessMetrics(image) else { return false }
        return metrics.averageLuma > 10.0 || metrics.brightPixelRatio > 0.02
    }

    private func frameBrightnessMetrics(_ image: CGImage) -> FrameBrightnessMetrics? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let sampleWidth = 64
        let sampleHeight = 64
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        let sampleRect = CGRect(
            x: CGFloat(width) * 0.25,
            y: CGFloat(height) * 0.25,
            width: CGFloat(width) * 0.5,
            height: CGFloat(height) * 0.5
        ).integral
        guard let cropped = image.cropping(to: sampleRect) else { return nil }

        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        let drewImage = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: sampleWidth,
                    height: sampleHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard drewImage else { return nil }

        var totalLuma = 0.0
        var brightPixels = 0
        let pixelCount = sampleWidth * sampleHeight
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let b = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let r = Double(pixels[index + 2])
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            totalLuma += luma
            if luma >= 40.0 {
                brightPixels += 1
            }
        }

        return FrameBrightnessMetrics(
            averageLuma: totalLuma / Double(pixelCount),
            brightPixelRatio: Double(brightPixels) / Double(pixelCount)
        )
    }

    /// 保存首帧为静态 fallback 壁纸（锁屏用）
    private func saveStaticFrame(_ image: CGImage, cacheKey: String) {
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.waifux.wallpaperengine/captured-frames")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let fileURL = cacheDir.appendingPathComponent("\(cacheKey).jpg")

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            print("[BakeService] ⚠️ 静态帧 JPEG 编码失败")
            return
        }
        do {
            try jpegData.write(to: fileURL)
            print("[BakeService] ✅ 静态帧已保存: \(fileURL.path)")
        } catch {
            print("[BakeService] ⚠️ 静态帧写入失败: \(error.localizedDescription)")
            return
        }
        WaifuXPreferences.shared.set(fileURL.path, forKey: cacheKey)

        // ⚠️ 动态锁屏启用时跳过设置静态桌面壁纸，
        // 避免覆盖用户在系统设置中手动选择的 WaifuX 锁屏实例。
        let shouldSkipForLockScreen: Bool = {
            if #available(macOS 26.0, *) {
                return VideoWallpaperManager.shared.isLockScreenEnabled
            }
            return false
        }()
        guard !shouldSkipForLockScreen else {
            print("[BakeService] 🔒 动态锁屏已启用，跳过设置静态 fallback 壁纸以保护用户锁屏选择")
            return
        }

        // 设为静态桌面壁纸（所有显示器）
        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
            .fillColor: NSColor.black
        ]
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURLForAllSpaces(fileURL, for: screen, options: fillOptions)
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(fileURL, for: screen, options: fillOptions)
                print("[BakeService] ✅ 静态 fallback 壁纸已设置 (screen: \(screen.localizedName))")
            } catch {
                print("[BakeService] ⚠️ 设置静态壁纸失败 (screen: \(screen.localizedName)): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 首帧捕获（供壁纸设置时获取缩略图）

    /// 启动 wallpaper-wgpu 渲染并等待首个有效帧，
    /// 捕获后立即终止进程，返回捕获的 CGImage。
    /// 用于「设为壁纸」时获取场景缩略图。
    func captureFirstValidFrame(
        scenePath: String,
        assetsPath: String? = nil,
        timeout: TimeInterval = 25
    ) async throws -> CGImage {
        // 权限检查
        if !checkScreenCapturePermission() {
            let granted = await requestScreenCapturePermission()
            guard granted else { throw BakeError.screenCaptureDenied }
        }

        // 解析 assets
        let resolvedAssets: String
        if let ap = assetsPath, !ap.isEmpty {
            resolvedAssets = ap
        } else if let embedded = await WallpaperEngineEmbeddedAssets.awaitAssetsReady() {
            resolvedAssets = embedded
        } else {
            resolvedAssets = ""
        }

        guard let cliURL = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
            throw BakeError.cliNotFound
        }

        let process = Process()
        process.executableURL = cliURL
        var args = ["--release", "--", scenePath]
        if !resolvedAssets.isEmpty {
            args += ["--assets", resolvedAssets]
        }
        args += ["--wallpaper", "--background"]
        process.arguments = args
        applyRendererLaunchEnvironment(to: process, executableURL: cliURL)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        let identity = OwnedProcessIdentity.capture(process.processIdentifier)
        defer {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                identity?.signal(SIGKILL)
            }
        }

        print("[BakeService] 首帧捕获进程已启动 (pid=\(process.processIdentifier)) (--wallpaper --background)")

        // 等待桌面层窗口并捕获首帧
        let windowInfo = try await waitForWindow(pid: process.processIdentifier, timeout: timeout)
        let windowID = windowInfo.windowID
        print("[BakeService] 桌面层窗口 ID=\(windowID) bounds=\(windowInfo.width)x\(windowInfo.height)")
        // --wallpaper 模式下窗口已在桌面层铺满显示器，无需移动

        // 轮询等待第一个非黑帧
        let startTime = Date()
        let pollInterval: TimeInterval = 0.5
        var lastImage: CGImage?

        while Date().timeIntervalSince(startTime) < timeout {
            guard process.isRunning else { throw BakeError.executionFailed("渲染进程意外退出") }

            if let image = await captureWindowFrame(
                windowID: windowID,
                captureWidth: max(1, windowInfo.width),
                captureHeight: max(1, windowInfo.height)
            ) {
                // 至少等待更久让场景完成暗到亮的加载，避免缓存黑屏/暗场帧
                if Date().timeIntervalSince(startTime) >= Self.minimumCaptureWarmup && isNonBlackFrame(image) {
                    print("[BakeService] ✅ 捕获到有效首帧")
                    return image
                }
                lastImage = image
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // 超时后返回最后一帧（即使可能是黑的）
        if let image = lastImage {
            print("[BakeService] ⚠️ 首帧超时，返回最后一帧")
            return image
        }

        throw BakeError.captureFailed("首帧捕获超时")
    }

    private func applyRendererLaunchEnvironment(to process: Process, executableURL: URL) {
        let rendererDirectory = executableURL.deletingLastPathComponent()
        process.currentDirectoryURL = rendererDirectory

        var env = process.environment ?? ProcessInfo.processInfo.environment
        let searchPaths = [
            rendererDirectory.path,
            rendererDirectory.deletingLastPathComponent().path,
            env["PATH"] ?? ""
        ].filter { !$0.isEmpty }
        env["PATH"] = searchPaths.joined(separator: ":")

        let libraryPaths = [
            rendererDirectory.appendingPathComponent("lib").path,
            env["DYLD_LIBRARY_PATH"] ?? ""
        ].filter { !$0.isEmpty }
        env["DYLD_LIBRARY_PATH"] = libraryPaths.joined(separator: ":")
        process.environment = env
    }

    private static func prepareRendererWrapper(for rendererURL: URL) throws -> RendererWrapperBundle {
        let fm = FileManager.default
        let cacheBase: URL
        if BackgroundRuntimeRole.isIsolatedTest,
           let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] {
            cacheBase = URL(fileURLWithPath: root).appendingPathComponent("BakeWrapperCache", isDirectory: true)
        } else {
            cacheBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        let bundleURL = cacheBase
            .appendingPathComponent("com.waifux.wallpaperengine", isDirectory: true)
            .appendingPathComponent("BakeRendererWrapper", isDirectory: true)
            .appendingPathComponent("WallpaperWGPUBakeAgent.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = macOSURL.appendingPathComponent("wallpaper-wgpu-launcher")

        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let bundleIdentifier: String
        if BackgroundRuntimeRole.isIsolatedTest {
            let service = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SERVICE"] ?? UUID().uuidString
            let suffix = service.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
            bundleIdentifier = "\(Self.rendererWrapperBundleIdentifier).test.\(String(suffix))"
        } else {
            bundleIdentifier = Self.rendererWrapperBundleIdentifier
        }
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>wallpaper-wgpu-launcher</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleIdentifier)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>Wallpaper WGPU Bake Agent</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSBackgroundOnly</key>
            <false/>
            <key>LSUIElement</key>
            <true/>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
        try infoPlist.data(using: .utf8)?.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)

        let launcher = """
        #!/bin/zsh
        cd \(Self.shellSingleQuoted(rendererURL.deletingLastPathComponent().path))
        exec \(Self.shellSingleQuoted(rendererURL.path)) "$@"
        """
        try launcher.data(using: .utf8)?.write(to: executableURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        return RendererWrapperBundle(
            bundleURL: bundleURL,
            executableURL: executableURL,
            renderedBinaryURL: rendererURL
        )
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func launchRendererWrapper(_ wrapper: RendererWrapperBundle, arguments: [String]) async throws -> pid_t {
        guard !processTerminationRequested else { throw CancellationError() }
        rendererLaunchesInProgress += 1
        defer {
            rendererLaunchesInProgress -= 1
            if rendererLaunchesInProgress == 0 {
                let waiters = rendererLaunchExitWaiters
                rendererLaunchExitWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        let rendererDirectory = wrapper.renderedBinaryURL.deletingLastPathComponent()
        let rendererLibDirectory = rendererDirectory.appendingPathComponent("lib")
        let bundleResourceDirectory = rendererDirectory.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment

        environment["PATH"] = [
            rendererDirectory.path,
            bundleResourceDirectory.path,
            environment["PATH"] ?? ""
        ].filter { !$0.isEmpty }.joined(separator: ":")
        environment["DYLD_LIBRARY_PATH"] = [
            rendererLibDirectory.path,
            bundleResourceDirectory.appendingPathComponent("lib").path,
            environment["DYLD_LIBRARY_PATH"] ?? ""
        ].filter { !$0.isEmpty }.joined(separator: ":")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.activates = false
        configuration.createsNewApplicationInstance = true

        let app = try await NSWorkspace.shared.openApplication(at: wrapper.bundleURL, configuration: configuration)
        if let identity = OwnedProcessIdentity.capture(app.processIdentifier) {
            rendererIdentities = [identity]
            // LaunchServices may report the PID before the launcher script has
            // exec'ed wgpu. Both executable phases share the captured birth time.
            let rendererPath = wrapper.renderedBinaryURL.standardizedFileURL.resolvingSymlinksInPath().path
            if identity.executablePath != rendererPath {
                rendererIdentities.append(OwnedProcessIdentity(pid: identity.pid, uid: identity.uid,
                    startedSeconds: identity.startedSeconds, startedMicroseconds: identity.startedMicroseconds,
                    executablePath: rendererPath))
            }
        }
        if processTerminationRequested {
            // A LaunchServices reply can arrive after shutdown started. Its
            // detached descendants still belong to this launch and must be
            // stopped before the wrapper is killed and they are reparented.
            prepareForProcessTermination()
        }
        return app.processIdentifier
    }

    private func terminateRenderer(pid: pid_t) {
        let identities = rendererIdentities.filter { $0.pid == pid }
        if !identities.isEmpty { retiringRendererIdentities[pid] = identities }
        for identity in identities { identity.signal(SIGCONT); identity.signal(SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            for identity in identities { identity.signal(SIGKILL) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let remaining = self.retiringRendererIdentities[pid]?.filter { $0.stillMatches() } ?? []
                if remaining.isEmpty { self.retiringRendererIdentities.removeValue(forKey: pid) }
                else { self.retiringRendererIdentities[pid] = remaining }
            }
        }
    }

    /// 将 CGImage 转换为 CVPixelBuffer 并追加到编码器
    private func appendFrame(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        writer: AVAssetWriter,
        cgImage: CGImage,
        sourceCropRect: CGRect? = nil,
        targetWidth: Int,
        targetHeight: Int,
        at presentationTime: CMTime
    ) throws {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw BakeError.writerFailed("CVPixelBufferCreate 失败")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw BakeError.writerFailed("PixelBuffer 基地址为空")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        guard let context = CGContext(
            data: base,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw BakeError.writerFailed("CGContext 创建失败")
        }

        let sourceImage: CGImage
        if let sourceCropRect,
           let cropped = cgImage.cropping(to: sourceCropRect.integral) {
            sourceImage = cropped
        } else {
            sourceImage = cgImage
        }

        let sourceAspect = CGFloat(sourceImage.width) / CGFloat(max(1, sourceImage.height))
        let targetAspect = CGFloat(targetWidth) / CGFloat(max(1, targetHeight))
        let drawRect: CGRect
        if sourceAspect > targetAspect {
            let drawWidth = CGFloat(targetHeight) * sourceAspect
            drawRect = CGRect(
                x: (CGFloat(targetWidth) - drawWidth) / 2,
                y: 0,
                width: drawWidth,
                height: CGFloat(targetHeight)
            )
        } else {
            let drawHeight = CGFloat(targetWidth) / max(sourceAspect, 0.0001)
            drawRect = CGRect(
                x: 0,
                y: (CGFloat(targetHeight) - drawHeight) / 2,
                width: CGFloat(targetWidth),
                height: drawHeight
            )
        }
        context.draw(sourceImage, in: drawRect)

        // 等待输入就绪（5ms 步进，最多 6 秒；替代原来 usleep(1ms) 的忙等，降低 CPU 占用）
        var waitCount = 0
        while !input.isReadyForMoreMediaData, waitCount < 1200 {
            Thread.sleep(forTimeInterval: 0.005)
            waitCount += 1
        }
        guard input.isReadyForMoreMediaData else {
            let statusDesc = "writerStatus=\(writer.status.rawValue)"
            throw BakeError.writerFailed("编码器未就绪 (\(statusDesc))")
        }

        guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
            throw BakeError.writerFailed(writer.error?.localizedDescription ?? "追加帧失败")
        }
    }
}

// MARK: - CoreGraphics 私有 API 桥接

/// CGS 窗口管理函数（私有 API，用于移动/隐藏窗口）
/// ⚠️ macOS 26 移除了 CGSWindowByID 和 CGSResizeWindow，此处全部声明为可选，找不到时不 crash。
private nonisolated(unsafe) let CGSDotSBack: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
}()

private typealias CGSWindowID = UInt32

// MARK: - macOS 26 兼容 CGS API
//
// macOS 26 移除了 CGSWindowByID 和 CGSResizeWindow。
// 改用 CGSGetOnScreenWindowList + CGSGetWindowOwner 查找窗口，
// CGSSetWindowShape + CGSNewRegionWithRect 替代 resize。
// CGSMoveWindow 在 macOS 26 上仍然可用。

private let CGSDefaultConnectionFn: (@convention(c) () -> UInt32)? = {
    guard let handle = CGSDotSBack else { return nil }
    guard let sym = dlsym(handle, "_CGSDefaultConnection") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> UInt32).self)
}()

private let CGSGetOnScreenWindowListFn: (@convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UInt32, UnsafeMutablePointer<UInt32>) -> CGError)? = {
    guard let handle = CGSDotSBack else { return nil }
    guard let sym = dlsym(handle, "CGSGetOnScreenWindowList") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UInt32, UnsafeMutablePointer<UInt32>) -> CGError).self)
}()

private let CGSGetWindowOwnerFn: (@convention(c) (UInt32, UInt32, UnsafeMutablePointer<pid_t>) -> CGError)? = {
    guard let handle = CGSDotSBack else { return nil }
    guard let sym = dlsym(handle, "CGSGetWindowOwner") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, UInt32, UnsafeMutablePointer<pid_t>) -> CGError).self)
}()

private let CGSMoveWindowFunc: (@convention(c) (UInt32, CGPoint) -> Void)? = {
    guard let handle = CGSDotSBack else { return nil }
    guard let sym = dlsym(handle, "CGSMoveWindow") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, CGPoint) -> Void).self)
}()

private let CGSNewRegionWithRectFn: (@convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<OpaquePointer?>) -> CGError)? = {
    guard let handle = CGSDotSBack else { return nil }
    guard let sym = dlsym(handle, "CGSNewRegionWithRect") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<OpaquePointer?>) -> CGError).self)
}()

private let CGSSetWindowShapeFn: (@convention(c) (UInt32, UInt32, OpaquePointer?) -> CGError)? = {
    guard let handle = CGSDotSBack else { return nil }
    guard let sym = dlsym(handle, "CGSSetWindowShape") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, UInt32, OpaquePointer?) -> CGError).self)
}()

private let CGSReleaseRegionFn: (@convention(c) (OpaquePointer?) -> CGError)? = {
    guard let handle = CGSDotSBack else { return nil }
    guard let sym = dlsym(handle, "CGSReleaseRegion") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (OpaquePointer?) -> CGError).self)
}()

/// macOS 26 上通过枚举 CGS 窗口列表查找 CGWindowID 对应的 CGS 窗口 ID。
private func findCGSWindowID(_ targetCGWindowID: CGWindowID, ownerPID: pid_t) -> UInt32? {
    guard let conn = CGSDefaultConnectionFn?(),
          let getList = CGSGetOnScreenWindowListFn,
          let getOwner = CGSGetWindowOwnerFn else { return nil }
    var count: UInt32 = 0
    guard getList(conn, nil, 0, &count) == .success, count > 0 else { return nil }
    var ids = [UInt32](repeating: 0, count: Int(count))
    var outCount: UInt32 = 0
    guard getList(conn, &ids, count, &outCount) == .success else { return nil }
    let validCount = min(Int(outCount), ids.count)
    for i in 0..<validCount {
        var pid: pid_t = 0
        if getOwner(conn, ids[i], &pid) == .success, pid == ownerPID {
            if let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
                for item in list {
                    guard let num = item[kCGWindowNumber as String] as? CGWindowID, num == targetCGWindowID else { continue }
                    guard let owner = item[kCGWindowOwnerPID as String] as? Int, owner == pid else { continue }
                    return ids[i]
                }
            }
        }
    }
    return nil
}

/// 检查是否有屏幕录制权限（同步，用于快速判断）
private func hasScreenCapturePermission() -> Bool {
    if #available(macOS 10.15, *) {
        return CGPreflightScreenCaptureAccess()
    }
    return true
}

/// 移动窗口（CGS 私有 API，macOS 26 仍可用）
private func CGSMoveWindow(_ cgsWindow: UInt32, _ point: CGPoint) {
    CGSMoveWindowFunc?(cgsWindow, point)
}

/// 调整窗口大小（macOS 26: CGSResizeWindow 已移除，改用 CGSSetWindowShape）
private func CGSResizeWindow(_ cgsWindow: UInt32, _ size: CGSize) {
    guard let setShape = CGSSetWindowShapeFn,
          let newRegion = CGSNewRegionWithRectFn,
          let releaseRegion = CGSReleaseRegionFn else { return }
    var rect = CGRect(origin: .zero, size: size)
    var region: OpaquePointer?
    guard newRegion(&rect, &region) == .success, let region else { return }
    _ = setShape(CGSDefaultConnectionFn?() ?? 0, cgsWindow, region)
    _ = releaseRegion(region)
}

/// 检查是否有屏幕录制权限
private func checkScreenCapturePermission() -> Bool {
    if #available(macOS 10.15, *) {
        return CGPreflightScreenCaptureAccess()
    }
    return true // 旧系统无权限限制
}

/// 请求屏幕录制权限（返回 true 表示已授权）
private func requestScreenCapturePermission() async -> Bool {
    if #available(macOS 10.15, *) {
        if CGPreflightScreenCaptureAccess() { return true }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let granted = CGRequestScreenCaptureAccess()
                continuation.resume(returning: granted)
            }
        }
    }
    return true
}

/// CGSSetWindowLevel — 设置窗口层级（私有 API），通过 dlsym 动态加载
private let CGSSetWindowLevelFunc: (@convention(c) (UInt32, Int32) -> Int32)? = {
    guard let handle = CGSDotSBack else { return nil }
    guard let sym = dlsym(handle, "CGSSetWindowLevel") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, Int32) -> Int32).self)
}()

private func CGSWindowSetLevel(_ cgsWindow: UInt32, _ level: Int32) {
    _ = CGSSetWindowLevelFunc?(cgsWindow, level)
}

// MARK: - 错误类型

enum BakeError: LocalizedError, Equatable {
    case alreadyBaking
    case cliNotFound
    case windowNotFound
    case windowPlacementFailed(String)
    case captureFailed(String)
    case writerFailed(String)
    case executionFailed(String)
    case cancelled
    case noScreenCapturePermission
    case screenCaptureDenied

    var errorDescription: String? {
        switch self {
        case .alreadyBaking: return "已有烘焙任务在进行中"
        case .cliNotFound: return "未找到 wallpaper-wgpu 二进制文件"
        case .windowNotFound: return "未找到渲染窗口"
        case .windowPlacementFailed(let msg): return msg
        case .captureFailed(let msg): return "帧捕获失败: \(msg)"
        case .writerFailed(let msg): return "视频编码失败: \(msg)"
        case .executionFailed(let msg): return msg
        case .cancelled: return "烘焙已取消"
        case .noScreenCapturePermission: return "需要屏幕录制权限才能烘焙视频"
        case .screenCaptureDenied: return "屏幕录制权限被拒绝，请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许本应用"
        }
    }
}
