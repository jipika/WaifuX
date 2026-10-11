import AppKit
import Foundation

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
              WaifuXPreferences.shared.bool(forKey: "system_wallpaper_sync_enabled") == systemSyncEnabled else {
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
                      !WaifuXPreferences.shared.bool(forKey: "system_wallpaper_sync_enabled") else {
                    if overlay.imageURL(for: screen)?.standardizedFileURL == imageURL.standardizedFileURL {
                        overlay.clearState(for: screen)
                    }
                    return
                }
            }
            return
        }

        let staticEntries = screens.compactMap { screen -> (NSScreen, URL)? in
            guard let imageURL = overlay.imageURL(for: screen),
                  FileManager.default.fileExists(atPath: imageURL.path) else {
                return nil
            }
            return (screen, imageURL)
        }
        guard !staticEntries.isEmpty else { return }

        let workspace = NSWorkspace.shared
        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true
        ]

        for (screen, imageURL) in staticEntries {
            guard !isTerminating, !Task.isCancelled, systemWallpaperSyncTransitionGeneration == generation,
                  WaifuXPreferences.shared.bool(forKey: "system_wallpaper_sync_enabled") else {
                return
            }

            let preparedURL = await overlay.preparedSystemWallpaperURL(for: imageURL)
            guard !isTerminating, !Task.isCancelled, systemWallpaperSyncTransitionGeneration == generation,
                  WaifuXPreferences.shared.bool(forKey: "system_wallpaper_sync_enabled") else {
                return
            }
            do {
                try workspace.setDesktopImageURLForAllSpaces(
                    preparedURL,
                    for: screen,
                    options: fillOptions
                )
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(
                    preparedURL,
                    for: screen,
                    options: fillOptions
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
    static func apply(from imageURL: URL, option: WallpaperOption) async throws {
        try checkCanApply()
        if BackgroundRuntimeRole.isRemoteUI { _ = try await BackgroundRuntimeBridge.request("wallpaper.static", ["url": imageURL, "option": option.rawValue]); return }

        VideoWallpaperManager.shared.cancelPendingExternalVideoTransition(
            reason: "WallpaperViewModel.setWallpaper"
        )
        let screens = NSScreen.screens
        SceneOfflineBakeService.cancelRealtimeCompanionBake(reason: "WallpaperViewModel.setWallpaper")
        let transitionToken = WallpaperCrossTypeTransitionCoordinator.shared
            .beginRequest(on: screens)
        let imageURLByScreen = try await preparedStaticImageURLs(
            from: imageURL,
            for: screens
        )
        guard isCurrent(
            transitionToken
        ) else {
            return
        }
        WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(
            on: screens,
            reason: "applyStaticWallpaper"
        )

        let preservesDynamicWallpaperUntilReady = VideoWallpaperManager.shared
            .hasNativeVideoWallpaper(on: screens)
            || screens.contains { WallpaperEngineXBridge.shared.isManaging(screen: $0) }
        if !preservesDynamicWallpaperUntilReady {
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()
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
        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            for screen in screens {
                guard let displayID = (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber)?.uint32Value else {
                    continue
                }
                let resolvedImageURL = imageURLByScreen[screen.wallpaperScreenIdentifier] ?? imageURL
                try await LockScreenWallpaperService.shared.cacheStaticImageSource(
                    imageURL: resolvedImageURL,
                    displayIDs: [displayID]
                )
                guard isCurrent(
                    transitionToken
                ) else {
                    return
                }
            }
            // 桌面：不写系统壁纸。扩展已在该屏渲染（活跃管线）时交给扩展原生显示，
            // 不再叠加 overlay——macOS 27 上不透明 overlay 会成为菜单栏背板的采样源，
            // 把采样和系统设置切壁纸一起冻住。仅扩展无活跃管线时用 overlay 兜底。
            for screen in screens {
                guard let displayID = (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber)?.uint32Value else {
                    continue
                }
                if WallpaperExtensionSocketServer.shared.hasActivePipeline(for: displayID) {
                    continue
                }
                let resolvedImageURL = imageURLByScreen[screen.wallpaperScreenIdentifier] ?? imageURL
                await StaticImageWallpaperOverlayManager.shared.showPrepared(
                    imageURL: resolvedImageURL,
                    for: screen
                )
                guard isCurrent(
                    transitionToken
                ) else {
                    return
                }
            }
            StaticWallpaperGrainManager.shared.updateOverlay()
            print("[StaticWallpaperApply] 🔒 动态锁屏已启用，静态图已同步到 WaifuX 锁屏实例 + 桌面 overlay")
            await finishStaticWallpaperTransitionIfNeeded(
                screens: screens,
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
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
                    for: screen
                )
                guard isCurrent(
                    transitionToken
                ) else {
                    return
                }
            }
            StaticWallpaperGrainManager.shared.updateOverlay()
            await finishStaticWallpaperTransitionIfNeeded(
                screens: screens,
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
            return
        }

        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true
        ]
        for screen in screens {
            let resolvedImageURL = imageURLByScreen[screen.wallpaperScreenIdentifier] ?? imageURL
            let systemWallpaperURL = await StaticImageWallpaperOverlayManager.shared.preparedSystemWallpaperURL(
                for: resolvedImageURL
            )
            guard isCurrent(
                transitionToken
            ) else {
                return
            }
            try workspace.setDesktopImageURLForAllSpaces(systemWallpaperURL, for: screen, options: fillOptions)
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(systemWallpaperURL, for: screen)
        }

        // 互斥：走系统壁纸时关闭并清除静态图 overlay 持久化状态
        StaticImageWallpaperOverlayManager.shared.clearState()

        // 更新静态壁纸颗粒蒙层（独立窗口，不受壁纸切换影响）
        StaticWallpaperGrainManager.shared.updateOverlay()
        await finishStaticWallpaperTransitionIfNeeded(
            screens: screens,
            preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
            requestToken: transitionToken
        )
    }

    // MARK: - 设置壁纸到指定屏幕
    /// - Note: macOS 的锁屏壁纸即桌面壁纸，没有独立的锁屏壁纸 API。
    ///   `.lockScreen` 和 `.both` 最终都等同于设置桌面壁纸。
    static func apply(from imageURL: URL, option: WallpaperOption, for targetScreen: NSScreen?) async throws {
        try checkCanApply()
        if BackgroundRuntimeRole.isRemoteUI { _ = try await BackgroundRuntimeBridge.request("wallpaper.staticScreen", ["url": imageURL, "option": option.rawValue, "screen": targetScreen]); return }

        VideoWallpaperManager.shared.cancelPendingExternalVideoTransition(
            reason: "WallpaperViewModel.setWallpaperForScreen"
        )
        SceneOfflineBakeService.cancelRealtimeCompanionBake(reason: "WallpaperViewModel.setWallpaperForScreen")
        let workspace = NSWorkspace.shared

        // 如果指定了特定屏幕，只设置到该屏幕
        if let targetScreen = targetScreen {
            let transitionToken = WallpaperCrossTypeTransitionCoordinator.shared
                .beginRequest(on: [targetScreen])
            let resolvedImageURL = try await preparedStaticImageURL(
                from: imageURL,
                for: targetScreen
            )
            guard isCurrent(
                transitionToken
            ) else {
                return
            }
            WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(
                on: [targetScreen],
                reason: "applyStaticWallpaperForScreen"
            )

            let preservesDynamicWallpaperUntilReady = VideoWallpaperManager.shared
                .hasNativeVideoWallpaper(on: [targetScreen])
                || WallpaperEngineXBridge.shared.isManaging(screen: targetScreen)

            // 切到静态图前如果目标屏幕被 CLI 管理则停 CLI 引擎
            if !preservesDynamicWallpaperUntilReady {
                if WallpaperEngineXBridge.shared.isManaging(screen: targetScreen) {
                    WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: targetScreen)
                }
                // 只停目标屏幕的动态壁纸，避免影响其他屏幕
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: targetScreen)
            }
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
            if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
                if let displayID = (targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                    try await LockScreenWallpaperService.shared.cacheStaticImageSource(
                        imageURL: resolvedImageURL,
                        displayIDs: [displayID]
                    )
                    guard isCurrent(
                        transitionToken
                    ) else {
                        return
                    }
                    await StaticImageWallpaperOverlayManager.shared.showPrepared(
                        imageURL: resolvedImageURL,
                        for: targetScreen
                    )
                    guard isCurrent(
                        transitionToken
                    ) else {
                        return
                    }
                    StaticWallpaperGrainManager.shared.updateOverlay()
                    print("[StaticWallpaperApply] 🔒 动态锁屏已启用，单屏静态图已同步到 WaifuX 实例 + 桌面 overlay")
                }
                await finishStaticWallpaperTransitionIfNeeded(
                    screens: [targetScreen],
                    preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                    requestToken: transitionToken
                )
                return
            }

            // 系统壁纸同步关闭时，冻结 setDesktopImageURL 链路，改走独立静态图 overlay 显示。
            // mp4/场景/web 动态壁纸不受影响；颗粒蒙层独立于系统壁纸，仍正常更新。
            if !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
                print("[StaticWallpaperApply] 🧊 系统壁纸同步已关闭，走单屏独立静态图 overlay 显示")
                await StaticImageWallpaperOverlayManager.shared.showPrepared(
                    imageURL: resolvedImageURL,
                    for: targetScreen
                )
                guard isCurrent(
                    transitionToken
                ) else {
                    return
                }
                StaticWallpaperGrainManager.shared.updateOverlay()
                await finishStaticWallpaperTransitionIfNeeded(
                    screens: [targetScreen],
                    preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                    requestToken: transitionToken
                )
                return
            }

            let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ]
            let systemWallpaperURL = await StaticImageWallpaperOverlayManager.shared.preparedSystemWallpaperURL(
                for: resolvedImageURL
            )
            guard isCurrent(
                transitionToken
            ) else {
                return
            }
            try workspace.setDesktopImageURLForAllSpaces(systemWallpaperURL, for: targetScreen, options: fillOptions)
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(systemWallpaperURL, for: targetScreen)

            // 互斥：走系统壁纸时关闭并清除静态图 overlay 持久化状态
            StaticImageWallpaperOverlayManager.shared.clearState(for: targetScreen)
            await finishStaticWallpaperTransitionIfNeeded(
                screens: [targetScreen],
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
        } else {
            try await apply(from: imageURL, option: option)
        }
    }

    private static func finishStaticWallpaperTransitionIfNeeded(
        screens: [NSScreen],
        preservesDynamicWallpaperUntilReady: Bool,
        requestToken: WallpaperCrossTypeTransitionCoordinator.RequestToken
    ) async {
        guard preservesDynamicWallpaperUntilReady else { return }
        guard isCurrent(
            requestToken
        ) else {
            return
        }
        let liveScreens = Self.uniqueLiveScreens(preferred: screens)
        guard !liveScreens.isEmpty else { return }
        // 独立静态 overlay 与视频窗处于同一 desktop level。overlay 准备完成时
        // 先把仍在播放的旧视频提回前方，避免新图片在黑场出现前闪一帧。
        VideoWallpaperManager.shared.keepNativeVideoPresentationFront(on: liveScreens)
        await WallpaperCrossTypeTransitionCoordinator.shared.commitPreparedContent(
            on: liveScreens,
            requestToken: requestToken
        ) {
            for screen in liveScreens {
                guard isCurrent(
                    requestToken
                ) else {
                    return
                }
                await WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaperForTransition(
                    for: screen
                )
                guard isCurrent(
                    requestToken
                ) else {
                    return
                }
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
