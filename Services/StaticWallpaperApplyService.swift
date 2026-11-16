import AppKit
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Applies static wallpaper without constructing any browsing UI state.
@MainActor
enum StaticWallpaperApplyService {
    private static var systemWallpaperSyncTransitionGeneration: UInt64 = 0
    private static var systemWallpaperSyncTask: Task<Void, Never>?
    private static var lastSystemSyncMode: Bool?
    private static var isTerminating = false

    static func prepareForProcessTermination() {
        isTerminating = true
        systemWallpaperSyncTransitionGeneration &+= 1
        systemWallpaperSyncTask?.cancel()
        systemWallpaperSyncTask = nil
    }

    private static func checkCanApply() throws {
        try Task.checkCancellation()
        guard !isTerminating, BackgroundRuntimeRole.allowsDesktopRendering else { throw CancellationError() }
    }

    private static func isCurrent(_ token: WallpaperCrossTypeTransitionCoordinator.RequestToken) -> Bool {
        !isTerminating && !Task.isCancelled && WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(token)
    }

    static func systemSyncModeChanged(_ enabled: Bool) {
        guard !isTerminating, BackgroundRuntimeRole.isHelper,
              BackgroundRuntimeRole.allowsDesktopRendering else { return }
        guard lastSystemSyncMode != enabled else { return }
        lastSystemSyncMode = enabled
        systemWallpaperSyncTransitionGeneration &+= 1
        let generation = systemWallpaperSyncTransitionGeneration
        systemWallpaperSyncTask?.cancel()
        systemWallpaperSyncTask = Task { await migrateStaticWallpaperPresentation(systemSyncEnabled: enabled, generation: generation) }
    }

    private static func migrateStaticWallpaperPresentation(
        systemSyncEnabled: Bool,
        generation: UInt64
    ) async {
        guard !isTerminating, !Task.isCancelled, systemWallpaperSyncTransitionGeneration == generation,
              VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled == systemSyncEnabled else {
            return
        }

        let screens = NSScreen.screens
        let overlay = StaticImageWallpaperOverlayManager.shared

        if !systemSyncEnabled {
            for screen in screens {
                guard !isTerminating, !Task.isCancelled, systemWallpaperSyncTransitionGeneration == generation,
                      !VideoWallpaperManager.shared.hasActiveWallpaper(on: screen),
                      !WallpaperEngineXBridge.shared.isManaging(screen: screen),
                      overlay.imageURL(for: screen) == nil,
                      let imageURL = DesktopWallpaperSyncManager.shared.imageURL(for: screen),
                      FileManager.default.fileExists(atPath: imageURL.path) else {
                    continue
                }
                await overlay.showPrepared(imageURL: imageURL, for: screen)
                guard !isTerminating, !Task.isCancelled, systemWallpaperSyncTransitionGeneration == generation,
                      !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else {
                    if overlay.imageURL(for: screen)?.standardizedFileURL == imageURL.standardizedFileURL {
                        overlay.clearState(for: screen)
                    }
                    return
                }
            }
            return
        }

        guard !VideoWallpaperManager.shared.shouldPreserveLockScreenWallpaperSelection else { return }
        let staticEntries = screens.compactMap { screen -> (NSScreen, URL)? in
            guard let imageURL = overlay.imageURL(for: screen),
                  FileManager.default.fileExists(atPath: imageURL.path) else {
                return nil
            }
            return (screen, imageURL)
        }
        guard !staticEntries.isEmpty else { return }

        let workspace = NSWorkspace.shared

        for (screen, imageURL) in staticEntries {
            guard !isTerminating, !Task.isCancelled, systemWallpaperSyncTransitionGeneration == generation,
                  VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled,
                  !VideoWallpaperManager.shared.shouldPreserveLockScreenWallpaperSelection else {
                return
            }

            let sourceURL = await originalStaticSourceURL(for: imageURL)
            let prepared: SystemStaticWallpaperPresentation
            do {
                prepared = try await preparedSystemWallpaper(from: sourceURL, for: screen)
            } catch {
                AppLogger.error(.wallpaper, "Failed to prepare system static wallpaper", metadata: [
                    "screen": screen.localizedName, "error": error.localizedDescription
                ])
                continue
            }
            guard !isTerminating, !Task.isCancelled, systemWallpaperSyncTransitionGeneration == generation,
                  VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled,
                  !VideoWallpaperManager.shared.shouldPreserveLockScreenWallpaperSelection else {
                return
            }
            do {
                try workspace.setDesktopImageURLForAllSpaces(
                    prepared.url,
                    for: screen,
                    options: prepared.options
                )
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(
                    prepared.url,
                    for: screen,
                    options: prepared.options,
                    sourceURL: sourceURL
                )
            } catch {
                AppLogger.error(.wallpaper, "Failed to migrate static overlay into system wallpaper", metadata: [
                    "screen": screen.localizedName,
                    "error": error.localizedDescription
                ])
                continue
            }

            if overlay.imageURL(for: screen)?.standardizedFileURL == imageURL.standardizedFileURL {
                overlay.clearState(for: screen)
            }
        }
    }

    // MARK: - 设置壁纸
    /// - Note: macOS 的锁屏壁纸即桌面壁纸，没有独立的锁屏壁纸 API。
    ///   `.lockScreen` 和 `.both` 最终都等同于设置桌面壁纸，避免重复操作。
    static func apply(
        from imageURL: URL, option: WallpaperOption, targetScreens: [NSScreen]? = nil,
        requestToken suppliedToken: WallpaperCrossTypeTransitionCoordinator.RequestToken? = nil
    ) async throws {
        try checkCanApply()
        if BackgroundRuntimeRole.isRemoteUI {
            if let targetScreens {
                _ = try await BackgroundRuntimeBridge.request("wallpaper.apply", [
                    "url": imageURL, "screens": targetScreens,
                    "options": try JSONEncoder().encode(LocalWallpaperApplyService.Options())])
            } else {
                _ = try await BackgroundRuntimeBridge.request("wallpaper.static", ["url": imageURL, "option": option.rawValue])
            }
            return
        }

        let screens = uniqueLiveScreens(preferred: targetScreens ?? NSScreen.screens)
        guard !screens.isEmpty else { throw CancellationError() }
        if let suppliedToken, WallpaperCrossTypeTransitionCoordinator.shared.subset(suppliedToken, screens: screens) == nil {
            throw CancellationError()
        }
        VideoWallpaperManager.shared.cancelPendingExternalVideoTransition(
            reason: "WallpaperViewModel.setWallpaper"
        )
        SceneOfflineBakeService.cancelRealtimeCompanionBake(reason: "WallpaperViewModel.setWallpaper")
        let transitionToken: WallpaperCrossTypeTransitionCoordinator.RequestToken
        if let suppliedToken {
            guard let subset = WallpaperCrossTypeTransitionCoordinator.shared.subset(suppliedToken, screens: screens) else {
                throw CancellationError()
            }
            transitionToken = subset
        } else {
            transitionToken = WallpaperCrossTypeTransitionCoordinator.shared.beginRequest(on: screens)
        }
        let imageURLByScreen = try await preparedStaticImageURLs(
            from: imageURL,
            for: screens
        )
        guard isCurrent(transitionToken) else { throw CancellationError() }
        WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(
            on: screens,
            reason: "applyStaticWallpaper"
        )

        let preservesDynamicWallpaperUntilReady = VideoWallpaperManager.shared
            .hasNativeVideoWallpaper(on: screens)
            || screens.contains { WallpaperEngineXBridge.shared.isManaging(screen: $0) }
        // The transition snapshot keeps the old frame visible while the static
        // image is prepared. It must not keep the old renderer alive: a Web CLI
        // window sits above the system desktop and otherwise hides the new image.
        for screen in screens {
            await WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaperForTransition(for: screen)
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
        }

        // macOS 26+：仅当用户未启用动态锁屏时才清空锁屏扩展状态。
        // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive。
        let shouldClearExtension: Bool = {
            if #available(macOS 26.0, *) {
                return !VideoWallpaperManager.shared.isLockScreenEnabled
            }
            return true
        }()
        if #available(macOS 26.0, *), shouldClearExtension {
            LockScreenWallpaperService.shared.clearMirroringSourceCache()
            VideoWallpaperManager.shared.clearExtensionState()
        }

        // macOS 26+：动态锁屏启用时，不走系统静态壁纸写入（setDesktopImageURL 会
        // 覆盖用户在系统设置中手动选择的 WaifuX 锁屏实例）。锁屏侧把静态图源直接
        // 部署给 WaifuX 显示器实例；桌面侧改走独立静态图 overlay 窗口显示，
        // 保证静态壁纸在每块屏上都真实可见。
        if #available(macOS 26.0, *), VideoWallpaperManager.shared.shouldPreserveLockScreenWallpaperSelection {
            try await prepareExtensionStaticWallpaper(
                imageURLs: imageURLByScreen, screens: screens, requestToken: transitionToken)
            guard isCurrent(transitionToken) else { throw CancellationError() }
            StaticWallpaperGrainManager.shared.updateOverlay()
            await finishStaticWallpaperTransitionIfNeeded(
                screens: screens,
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
            guard isCurrent(transitionToken) else { throw CancellationError() }
            return
        }

        let workspace = NSWorkspace.shared

        // 系统壁纸同步关闭时，冻结 setDesktopImageURL 链路，改走独立静态图 overlay 显示。
        // mp4/场景/web 动态壁纸不受影响（它们通过 overlay 窗口或 CLI 进程覆盖桌面）。
        // 颗粒蒙层独立于系统壁纸，仍正常更新。
        if !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
            print("[StaticWallpaperApply] 🧊 系统壁纸同步已关闭，走独立静态图 overlay 显示")
            for screen in screens {
                let resolvedImageURL = imageURLByScreen[screen.wallpaperScreenIdentifier] ?? imageURL
                await StaticImageWallpaperOverlayManager.shared.showPrepared(
                    imageURL: resolvedImageURL,
                    for: screen,
                    isCurrent: { isCurrent(transitionToken) }
                )
                guard isCurrent(transitionToken) else { throw CancellationError() }
            }
            StaticWallpaperGrainManager.shared.updateOverlay()
            await finishStaticWallpaperTransitionIfNeeded(
                screens: screens,
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
            guard isCurrent(transitionToken) else { throw CancellationError() }
            return
        }

        for screen in screens {
            let prepared = try await preparedSystemWallpaper(from: imageURL, for: screen)
            guard isCurrent(transitionToken) else { throw CancellationError() }
            try workspace.setDesktopImageURLForAllSpaces(prepared.url, for: screen, options: prepared.options)
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(
                prepared.url, for: screen, options: prepared.options, sourceURL: imageURL)
        }

        // Only target screens retire their overlay; a subset apply must leave
        // unrelated displays and their persisted sources untouched.
        for screen in screens { StaticImageWallpaperOverlayManager.shared.clearState(for: screen) }

        // 更新静态壁纸颗粒蒙层（独立窗口，不受壁纸切换影响）
        StaticWallpaperGrainManager.shared.updateOverlay()
        await finishStaticWallpaperTransitionIfNeeded(
            screens: screens,
            preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
            requestToken: transitionToken
        )
        guard isCurrent(transitionToken) else { throw CancellationError() }
    }

    // MARK: - 设置壁纸到指定屏幕
    /// - Note: macOS 的锁屏壁纸即桌面壁纸，没有独立的锁屏壁纸 API。
    ///   `.lockScreen` 和 `.both` 最终都等同于设置桌面壁纸。
    static func apply(
        from imageURL: URL, option: WallpaperOption, for targetScreen: NSScreen?,
        requestToken suppliedToken: WallpaperCrossTypeTransitionCoordinator.RequestToken? = nil
    ) async throws {
        try checkCanApply()
        if BackgroundRuntimeRole.isRemoteUI { _ = try await BackgroundRuntimeBridge.request("wallpaper.staticScreen", ["url": imageURL, "option": option.rawValue, "screen": targetScreen]); return }

        VideoWallpaperManager.shared.cancelPendingExternalVideoTransition(
            reason: "WallpaperViewModel.setWallpaperForScreen"
        )
        SceneOfflineBakeService.cancelRealtimeCompanionBake(reason: "WallpaperViewModel.setWallpaperForScreen")
        let workspace = NSWorkspace.shared

        // 如果指定了特定屏幕，只设置到该屏幕
        if let targetScreen = targetScreen {
            let transitionToken: WallpaperCrossTypeTransitionCoordinator.RequestToken
            if let suppliedToken {
                guard let subset = WallpaperCrossTypeTransitionCoordinator.shared.subset(suppliedToken, screens: [targetScreen]) else {
                    throw CancellationError()
                }
                transitionToken = subset
            } else {
                transitionToken = WallpaperCrossTypeTransitionCoordinator.shared.beginRequest(on: [targetScreen])
            }
            let resolvedImageURL = try await preparedStaticImageURL(
                from: imageURL,
                for: targetScreen
            )
            guard isCurrent(transitionToken) else { throw CancellationError() }
            WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(
                on: [targetScreen],
                reason: "applyStaticWallpaperForScreen"
            )

            let preservesDynamicWallpaperUntilReady = VideoWallpaperManager.shared
                .hasNativeVideoWallpaper(on: [targetScreen])
                || WallpaperEngineXBridge.shared.isManaging(screen: targetScreen)

            // The transition snapshot preserves the old frame visually, but the
            // old renderer must be torn down before the system desktop is set.
            // Otherwise a Web CLI window remains above the new static wallpaper.
            await WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaperForTransition(for: targetScreen)
            // 只停目标屏幕的动态壁纸，避免影响其他屏幕
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: targetScreen)
            // macOS 26+：仅当用户未启用动态锁屏时才清空锁屏镜像帧源缓存。
            // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive。
            let shouldClearExtension: Bool = {
                if #available(macOS 26.0, *) {
                    return !VideoWallpaperManager.shared.isLockScreenEnabled
                }
                return true
            }()
            if #available(macOS 26.0, *), shouldClearExtension {
                LockScreenWallpaperService.shared.clearMirroringSourceCache()
            }

            // macOS 26+：动态锁屏启用时，不走系统静态壁纸写入（会覆盖用户手动
            // 选择的锁屏实例）。锁屏侧部署给该显示器的 WaifuX 实例；桌面侧走
            // 独立静态图 overlay 显示，保证目标屏真实可见。
            if #available(macOS 26.0, *), VideoWallpaperManager.shared.shouldPreserveLockScreenWallpaperSelection {
                try await prepareExtensionStaticWallpaper(
                    imageURLs: [targetScreen.wallpaperScreenIdentifier: resolvedImageURL],
                    screens: [targetScreen], requestToken: transitionToken)
                guard isCurrent(transitionToken) else { throw CancellationError() }
                StaticWallpaperGrainManager.shared.updateOverlay()
                await finishStaticWallpaperTransitionIfNeeded(
                    screens: [targetScreen],
                    preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                    requestToken: transitionToken
                )
                guard isCurrent(transitionToken) else { throw CancellationError() }
                return
            }

            // 系统壁纸同步关闭时，冻结 setDesktopImageURL 链路，改走独立静态图 overlay 显示。
            // mp4/场景/web 动态壁纸不受影响；颗粒蒙层独立于系统壁纸，仍正常更新。
            if !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
                print("[StaticWallpaperApply] 🧊 系统壁纸同步已关闭，走单屏独立静态图 overlay 显示")
                await StaticImageWallpaperOverlayManager.shared.showPrepared(
                    imageURL: resolvedImageURL,
                    for: targetScreen,
                    isCurrent: { isCurrent(transitionToken) }
                )
                guard isCurrent(transitionToken) else { throw CancellationError() }
                StaticWallpaperGrainManager.shared.updateOverlay()
                await finishStaticWallpaperTransitionIfNeeded(
                    screens: [targetScreen],
                    preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                    requestToken: transitionToken
                )
                guard isCurrent(transitionToken) else { throw CancellationError() }
                return
            }

            let prepared = try await preparedSystemWallpaper(from: imageURL, for: targetScreen)
            guard isCurrent(transitionToken) else { throw CancellationError() }
            try workspace.setDesktopImageURLForAllSpaces(prepared.url, for: targetScreen, options: prepared.options)
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(
                prepared.url, for: targetScreen, options: prepared.options, sourceURL: imageURL)

            // 互斥：走系统壁纸时关闭并清除静态图 overlay 持久化状态
            StaticImageWallpaperOverlayManager.shared.clearState(for: targetScreen)
            await finishStaticWallpaperTransitionIfNeeded(
                screens: [targetScreen],
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
            guard isCurrent(transitionToken) else { throw CancellationError() }
        } else {
            try await apply(from: imageURL, option: option, requestToken: suppliedToken)
        }
    }

    /// 把静态图源推给扩展，等扩展真正换图完成后再提交桌面呈现。
    @available(macOS 26.0, *)
    private static func prepareExtensionStaticWallpaper(
        imageURLs: [String: URL], screens: [NSScreen],
        requestToken: WallpaperCrossTypeTransitionCoordinator.RequestToken
    ) async throws {
        let current: @MainActor () -> Bool = { isCurrent(requestToken) }
        for screen in screens {
            guard current(), let imageURL = imageURLs[screen.wallpaperScreenIdentifier],
                  let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
                throw CancellationError()
            }
            try await LockScreenWallpaperService.shared.cacheStaticImageSource(
                imageURL: imageURL, displayIDs: [displayID], waitForReady: true, isCurrent: current)
            if !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled
                || VideoWallpaperManager.shared.isScreenLocked {
                await StaticImageWallpaperOverlayManager.shared.showPrepared(
                    imageURL: imageURL, for: screen, isCurrent: current)
            } else {
                StaticImageWallpaperOverlayManager.shared.clearState(for: screen)
            }
        }
    }

    private static func finishStaticWallpaperTransitionIfNeeded(
        screens: [NSScreen],
        preservesDynamicWallpaperUntilReady: Bool,
        requestToken: WallpaperCrossTypeTransitionCoordinator.RequestToken
    ) async {
        guard preservesDynamicWallpaperUntilReady, !isTerminating else { return }
        let coordinator = WallpaperCrossTypeTransitionCoordinator.shared
        // All sources have already passed preparation. Retire only screens this
        // request still owns: a later single-screen request must not strand the
        // untouched screens behind their old native/Scene presentation.
        for screen in Self.uniqueLiveScreens(preferred: screens) {
            guard let screenToken = coordinator.request(requestToken, for: screen) else { continue }
            VideoWallpaperManager.shared.keepNativeVideoPresentationFront(on: [screen])
            await coordinator.commitPreparedContent(on: [screen], requestToken: screenToken) {
                guard !isTerminating, coordinator.isCurrent(screenToken) else { return }
                await WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaperForTransition(for: screen)
                guard !isTerminating, coordinator.isCurrent(screenToken) else { return }
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
            }
        }
    }

    private static func uniqueLiveScreens(preferred: [NSScreen]) -> [NSScreen] {
        let live = NSScreen.screens
        var byID: [String: NSScreen] = [:]
        var byFingerprint: [String: NSScreen] = [:]
        for screen in live {
            byID[screen.wallpaperScreenIdentifier] = screen
            byFingerprint[screen.wallpaperScreenFingerprint] = screen
        }
        var seen = Set<String>()
        return preferred.compactMap { screen in
            let resolved = byID[screen.wallpaperScreenIdentifier]
                ?? byFingerprint[screen.wallpaperScreenFingerprint]
            guard let resolved, seen.insert(resolved.wallpaperScreenIdentifier).inserted else {
                return nil
            }
            return resolved
        }
    }

    struct SystemStaticWallpaperPresentation {
        let url: URL
        let options: [NSWorkspace.DesktopImageOptionKey: Any]
    }

    static func originalStaticSourceURL(for url: URL) async -> URL {
        await PortraitBlurFillWallpaperService.shared.originalSourceURL(
            forDerivedWallpaperAt: url,
            derivedWallpapersDirectory: DownloadPathManager.shared.derivedWallpapersFolderURL) ?? url
    }

    static func preparedSystemWallpaper(from imageURL: URL, for screen: NSScreen) async throws -> SystemStaticWallpaperPresentation {
        let sourceURL = await originalStaticSourceURL(for: imageURL)
        let settings = DisplayCropSettingsStore.shared.settings(for: screen)
        let effective = settings.isEnabled ? settings : .defaultSettings
        let isDefault = effective.displayMode == .fill && effective.aspectPreset == .autoFill
            && abs(effective.zoom - 1) < 0.000001 && effective.pan == CGPoint(x: 0.5, y: 0.5)
        if isDefault {
            let portraitURL = try await preparedStaticImageURL(from: sourceURL, for: screen)
            let url = await StaticImageWallpaperOverlayManager.shared.preparedSystemWallpaperURL(for: portraitURL)
            return SystemStaticWallpaperPresentation(url: url, options: [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue), .allowClipping: true])
        }
        let size = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                          height: screen.frame.height * screen.backingScaleFactor)
        // Non-default modes also use the blur-filled image when the toggle is
        // on, so the generated background is visible in every display mode.
        let composedSource = try await preparedStaticImageURL(from: sourceURL, for: screen)
        let cache = DownloadPathManager.shared.derivedWallpapersFolderURL.appendingPathComponent("DisplayLayouts", isDirectory: true)
        let url = try await SystemStaticWallpaperCompositor.shared.render(sourceURL: composedSource, screenPixels: size,
                                                                         settings: effective, directory: cache)
        return SystemStaticWallpaperPresentation(url: url, options: [
            .imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue), .allowClipping: false])
    }

    /// 仅在设置打开时为竖图生成派生壁纸。结果按显示器像素尺寸独立映射，
    /// 同一原图在不同宽高比的显示器上不会相互覆盖。
    private static func preparedStaticImageURLs(
        from sourceURL: URL,
        for screens: [NSScreen]
    ) async throws -> [String: URL] {
        guard WaifuXPreferences.shared.bool(forKey: "portrait_blur_fill_enabled") else {
            return Dictionary(uniqueKeysWithValues: screens.map {
                ($0.wallpaperScreenIdentifier, sourceURL)
            })
        }

        let derivedDirectory = DownloadPathManager.shared.derivedWallpapersFolderURL
        var imageURLs: [String: URL] = [:]
        for screen in screens {
            try checkCanApply()
            // Blur fill applies to every display mode when the user toggle is
            // on; the generated image already matches the screen aspect, so
            // fit/center/tile/stretch operate on it just like on any source.
            let pixelSize = CGSize(
                width: max(1, (screen.frame.width * screen.backingScaleFactor).rounded()),
                height: max(1, (screen.frame.height * screen.backingScaleFactor).rounded())
            )
            imageURLs[screen.wallpaperScreenIdentifier] = try await PortraitBlurFillWallpaperService.shared
                .preparedWallpaperURL(
                    for: sourceURL,
                    targetPixelSize: pixelSize,
                    derivedWallpapersDirectory: derivedDirectory
                )
        }
        return imageURLs
    }

    private static func preparedStaticImageURL(
        from sourceURL: URL,
        for screen: NSScreen
    ) async throws -> URL {
        let imageURLs = try await preparedStaticImageURLs(from: sourceURL, for: [screen])
        return imageURLs[screen.wallpaperScreenIdentifier] ?? sourceURL
    }

}

/// A single decode/composition worker; it never contacts the desktop or preferences.
private actor SystemStaticWallpaperCompositor {
    static let shared = SystemStaticWallpaperCompositor()

    func render(sourceURL: URL, screenPixels: CGSize, settings: DisplayCropSettings, directory: URL) throws -> URL {
        try Task.checkCancellation()
        guard screenPixels.width.isFinite, screenPixels.height.isFinite,
              screenPixels.width > 0, screenPixels.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let encoded = try JSONEncoder().encode(settings)
        let stamp = "\(sourceURL.standardizedFileURL.path)|\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? Date.distantPast)|\(screenPixels.width)x\(screenPixels.height)|v1|"
        let digest = SHA256.hash(data: Data(stamp.utf8) + encoded).map { String(format: "%02x", $0) }.joined()
        let output = directory.appendingPathComponent(digest).appendingPathExtension("jpg")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let decoded = try WallpaperBoundedImageDecoder.decode(url: sourceURL).get()
        // The bounded bitmap is drawn into a frame computed in oriented source
        // coordinates. That preserves original-pixel center/tile periods while
        // keeping decode memory bounded.
        let layout = CropLayoutEngine.compute(wallpaperSize: decoded.sourceSize, screenSize: screenPixels, settings: settings)
        let ratio = min(1, min(8192 / max(screenPixels.width, screenPixels.height),
                               sqrt(33_554_432 / (screenPixels.width * screenPixels.height))))
        let width = max(1, Int((screenPixels.width * ratio).rounded(.down)))
        let height = max(1, Int((screenPixels.height * ratio).rounded(.down)))
        let viewport = CGRect(x: layout.viewportRect.x * Double(width),
                              y: (1 - layout.viewportRect.y - layout.viewportRect.h) * Double(height),
                              width: layout.viewportRect.w * Double(width), height: layout.viewportRect.h * Double(height))
        let crop = layout.wallpaperCropRect
        let mediaWidth = viewport.width / crop.w, mediaHeight = viewport.height / crop.h
        var frame = CGRect(x: viewport.minX - crop.x * mediaWidth,
                           y: viewport.minY - (1 - crop.y - crop.h) * mediaHeight,
                           width: mediaWidth, height: mediaHeight)
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        if layout.isTiled {
            let x = frame.minX - viewport.minX
            let y = frame.minY - viewport.minY
            let firstX = x - ceil(x / frame.width) * frame.width
            let firstY = y - ceil(y / frame.height) * frame.height
            let copies = ceil((viewport.width - firstX) / frame.width) * ceil((viewport.height - firstY) / frame.height)
            guard copies.isFinite, copies <= 65_536 else { throw CocoaError(.coderInvalidValue) }
            frame.origin = CGPoint(x: viewport.minX + firstX, y: viewport.minY + firstY)
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.coderInvalidValue)
        }
        context.setFillColor(layout.letterboxColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.clip(to: viewport)
        context.interpolationQuality = .high
        context.draw(decoded.image, in: frame, byTiling: layout.isTiled)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        // Encode to memory and atomically publish only complete bytes.
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data as Data).write(to: output, options: .atomic)
        return output
    }
}
