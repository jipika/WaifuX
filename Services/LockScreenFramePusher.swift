//  锁屏帧推送服务
//
//  解码视频帧并推送到扩展的 IOSurface。
//  替代文件复制 + 扩展自行解码的方案。

import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface
import os

final class LockScreenFramePusher {
    nonisolated(unsafe) static let shared = LockScreenFramePusher()

    private let sessionsLock = OSAllocatedUnfairLock(initialState: [UInt32: Session]())

    private init() {}

    func startPushing(displayID: UInt32, videoURL: URL, surfaceIDs: [IOSurfaceID]) {
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        let oldSession = sessionsLock.withLock { sessions -> Session? in
            let old = sessions[displayID]
            if old?.matches(videoURL: videoURL, surfaceIDs: surfaceIDs) == true {
                return nil
            }
            sessions.removeValue(forKey: displayID)
            return old
        }
        if oldSession == nil, sessionsLock.withLock({ $0[displayID]?.matches(videoURL: videoURL, surfaceIDs: surfaceIDs) == true }) {
            os_log(.debug, log: Session.sessionLog, "[FramePusher] 已在推送，跳过重复启动 display=%{public}u video=%{public}@", displayID, videoURL.lastPathComponent)
            return
        }
        oldSession?.stop()
        let session = Session(displayID: displayID, videoURL: videoURL, surfaceIDs: surfaceIDs)
        sessionsLock.withLock { $0[displayID] = session }
        session.start()
        os_log(.info, log: Session.sessionLog, "[FramePusher] 开始推送 display=%{public}u video=%{public}@", displayID, videoURL.lastPathComponent)
    }

    func stopPushing(displayID: UInt32) {
        let session = sessionsLock.withLock { sessions -> Session? in
            sessions.removeValue(forKey: displayID)
        }
        session?.stop()
    }

    func stopAll() {
        let all = sessionsLock.withLock { sessions -> [Session] in
            let copy = Array(sessions.values)
            sessions.removeAll()
            return copy
        }
        for session in all { session.stop() }
    }

    /// 检查指定显示器是否有活跃的帧推送会话（用于健康检查）
    func isPushing(displayID: UInt32) -> Bool {
        sessionsLock.withLock { $0[displayID] != nil }
    }

    /// 获取所有活跃推送的显示器 ID 列表
    func activeDisplayIDs() -> [UInt32] {
        sessionsLock.withLock { Array($0.keys) }
    }
}

// MARK: - Session

extension LockScreenFramePusher {
    final class Session: @unchecked Sendable {
        fileprivate static let sessionLog = OSLog(subsystem: "com.waifux.app", category: "FramePusher")
        let displayID: UInt32
        let videoURL: URL
        let surfaceIDs: [IOSurfaceID]
        private lazy var queue: DispatchQueue = .init(label: "frame-pusher-\(displayID)", qos: .userInitiated)
        private var isRunning = false
        private var hasLoggedFirstFrame = false
        private var missingSurfaceLogCount = 0
        private var consecutiveSurfaceFailures = 0
        private let maxConsecutiveFailures = 30  // ~1 秒 @ 30fps

        // CGContext 缓存：避免逐帧创建/销毁（双缓冲下每 2 帧复用同一 surface）
        private var lastDstSurface: IOSurface?
        private var lastDstContext: CGContext?

        fileprivate init(displayID: UInt32, videoURL: URL, surfaceIDs: [IOSurfaceID]) {
            self.displayID = displayID
            self.videoURL = videoURL
            self.surfaceIDs = surfaceIDs
        }

        fileprivate func matches(videoURL: URL, surfaceIDs: [IOSurfaceID]) -> Bool {
            self.videoURL == videoURL && self.surfaceIDs == surfaceIDs && isRunning
        }

        fileprivate func start() {
            isRunning = true
            queue.async { [weak self] in
                self?.pushLoop()
            }
        }

        fileprivate func stop() {
            isRunning = false
            queue.async { [weak self] in
                self?.lastDstSurface = nil
                self?.lastDstContext = nil
            }
        }

        /// 尝试从服务端刷新 surface ID（扩展重建 surface 后 ID 会变化）
        private func refreshSurfaceIDs() -> [IOSurfaceID] {
            let refreshed = WallpaperExtensionSocketServer.shared.surfaceIDs(for: displayID)
            if !refreshed.isEmpty, refreshed != surfaceIDs {
                os_log(.info, log: Self.sessionLog, "🔄 surface ID 已刷新 display=%{public}u old=%{public}@ new=%{public}@",
                       displayID, surfaceIDs.description, refreshed.description)
            }
            return refreshed.isEmpty ? surfaceIDs : refreshed
        }

        /// 通知服务端 pusher 已停止，通过 socket server 的 retry 机制尝试恢复。
        /// 走 retry 机制而非直接 dispatch 全局队列，避免 zombie 访问。
        private func notifyPusherStopped(reason: String) {
            isRunning = false
            disposeCachedContext()
            os_log(.info, log: Self.sessionLog, "🛑 FramePusher 已停止 display=%{public}u reason: %{public}@", displayID, reason)
            // 无视频轨道是致命错误（URL 指向无效文件），重试无意义，不自动恢复
            if reason == "无视频轨道" {
                os_log(.info, log: Self.sessionLog, "⛔ display=%{public}u 视频源无效，放弃自动恢复", displayID)
                return
            }
            // 通过 socket server 的 scheduleRetry 机制自动恢复（会检查 surface 是否就绪）
            WallpaperExtensionSocketServer.shared.scheduleRetryForRestart(displayID: displayID)
        }

        /// 安全释放缓存的 CGContext（必须在 pushLoop 已退出或同一队列上调用）
        private func disposeCachedContext() {
            lastDstSurface = nil
            lastDstContext = nil
        }

        private func pushLoop() {
            guard isRunning else { return }
            guard !surfaceIDs.isEmpty else {
                os_log(.info, log: Self.sessionLog, "[FramePusher] ⚠️ 未注册任何 surface，停止推帧 display=%{public}u", displayID)
                return
            }

            let asset = AVURLAsset(url: videoURL)
            let semaphore = DispatchSemaphore(value: 0)
            final class TrackBox: @unchecked Sendable { var track: AVAssetTrack?; var fps: Float = 0 }
            let box = TrackBox()
            DispatchQueue.global().async {
                Task {
                    let tracks = try? await asset.loadTracks(withMediaType: .video)
                    box.track = tracks?.first
                    if let t = box.track {
                        box.fps = (try? await t.load(.nominalFrameRate)) ?? 0
                    }
                    semaphore.signal()
                }
            }
            semaphore.wait()
            guard let track = box.track else {
                os_log(.error, log: Self.sessionLog, "[FramePusher] ❌ 无视频轨道: %{public}@", videoURL.lastPathComponent)
                notifyPusherStopped(reason: "无视频轨道")
                return
            }

            var frameIndex = 0
            var ptsOffset: CMTime = .zero
            var lastEnqueuedEnd: CMTime = .zero
            var currentSurfaceIDs = surfaceIDs
            let nominalFPS = box.fps > 0 ? box.fps : 30
            let fallbackFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(nominalFPS.rounded()))))
            let convergenceCheckInterval = 60  // 每 ~2 秒检查一次 surface ID 是否更新

            while isRunning {
                guard let reader = try? AVAssetReader(asset: asset) else {
                    os_log(.error, log: Self.sessionLog, "[FramePusher] ❌ AVAssetReader 创建失败: %{public}@", videoURL.lastPathComponent)
                    notifyPusherStopped(reason: "AVAssetReader 创建失败")
                    return
                }

                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    os_log(.error, log: Self.sessionLog, "[FramePusher] ❌ 无法添加 TrackOutput: %{public}@", videoURL.lastPathComponent)
                    notifyPusherStopped(reason: "无法添加 TrackOutput")
                    return
                }
                reader.add(output)

                guard reader.startReading() else {
                    let message = reader.error?.localizedDescription ?? "unknown"
                    os_log(.error, log: Self.sessionLog, "[FramePusher] ❌ startReading 失败: %{public}@", message)
                    notifyPusherStopped(reason: "startReading 失败: \(message)")
                    return
                }
                os_log(.info, log: Self.sessionLog, "startReading display=%{public}u video=%{public}@", displayID, videoURL.lastPathComponent)

                var reachedEnd = false

                while isRunning, reader.status == .reading {
                    autoreleasepool {
                        guard let sample = output.copyNextSampleBuffer() else {
                            reachedEnd = true
                            return
                        }

                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }

                        // 定期刷新 surface ID（扩展重建后 ID 可能变化）
                        if frameIndex > 0, frameIndex % convergenceCheckInterval == 0 {
                            let refreshed = refreshSurfaceIDs()
                            if refreshed != currentSurfaceIDs {
                                currentSurfaceIDs = refreshed
                                os_log(.info, log: Self.sessionLog, "🔄 已更新 surface ID display=%{public}u", displayID)
                            }
                        }

                        let idleIndex = frameIndex % currentSurfaceIDs.count
                        let surfaceID = currentSurfaceIDs[idleIndex]
                        guard let ref = IOSurfaceLookup(surfaceID) else {
                            consecutiveSurfaceFailures += 1
                            if missingSurfaceLogCount < 5 {
                                missingSurfaceLogCount += 1
                                os_log(.error, log: Self.sessionLog, "IOSurfaceLookup failed display=%{public}u surface=%{public}u attempt=%{public}d consecutive=%{public}d",
                                       displayID, surfaceID, missingSurfaceLogCount, consecutiveSurfaceFailures)
                            } else if consecutiveSurfaceFailures % 300 == 0 {
                                os_log(.error, log: Self.sessionLog, "IOSurfaceLookup 持续失败 display=%{public}u consecutive=%{public}d，尝试刷新 surface ID...",
                                       displayID, consecutiveSurfaceFailures)
                                let refreshed = refreshSurfaceIDs()
                                if refreshed != currentSurfaceIDs {
                                    currentSurfaceIDs = refreshed
                                    consecutiveSurfaceFailures = 0
                                    os_log(.info, log: Self.sessionLog, "✅ surface ID 已刷新 display=%{public}u new=%{public}@", displayID, refreshed.description)
                                }
                            }
                            if consecutiveSurfaceFailures >= maxConsecutiveFailures * 10 {
                                os_log(.error, log: Self.sessionLog, "❌ IOSurfaceLookup 连续失败过多 display=%{public}u，停止推帧并等待恢复", displayID)
                                notifyPusherStopped(reason: "IOSurfaceLookup 连续失败过多")
                                return
                            }
                            usleep(33_000)
                            return
                        }
                        consecutiveSurfaceFailures = 0
                        let surface = unsafeBitCast(ref, to: IOSurface.self)
                        writePixelBuffer(pixelBuffer, to: surface)

                        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                        let sampleDuration = CMSampleBufferGetDuration(sample)
                        let effectiveDuration = sampleDuration.isValid && sampleDuration > .zero
                            ? sampleDuration
                            : fallbackFrameDuration

                        let pts = CMTimeAdd(rawPTS, ptsOffset)
                        lastEnqueuedEnd = CMTimeAdd(pts, effectiveDuration)

                        pushFrameToExtension(displayID: displayID, surfaceID: surfaceID, pts: pts, duration: effectiveDuration)
                        if !hasLoggedFirstFrame {
                            hasLoggedFirstFrame = true
                            os_log(.info, log: Self.sessionLog, "first frame pushed display=%{public}u surface=%{public}u pts=%{public}.3f", displayID, surfaceID, pts.seconds)
                        }

                        frameIndex += 1

                        let sleepTime = effectiveDuration.seconds
                        if sleepTime > 0 {
                            usleep(useconds_t(min(sleepTime, 1.0) * 1_000_000))
                        }
                    }
                }

                reader.cancelReading()

                if !isRunning { break }

                switch reader.status {
                case .completed:
                    ptsOffset = lastEnqueuedEnd
                    continue
                case .failed:
                    let message = reader.error?.localizedDescription ?? "unknown"
                    os_log(.error, log: Self.sessionLog, "[FramePusher] ❌ 读取失败: %{public}@", message)
                    notifyPusherStopped(reason: "读取失败: \(message)")
                    return
                case .cancelled:
                    return
                case .reading:
                    if reachedEnd {
                        continue
                    }
                case .unknown:
                    os_log(.info, log: Self.sessionLog, "[FramePusher] ⚠️ Reader 状态未知，停止推帧 display=%{public}u", displayID)
                    notifyPusherStopped(reason: "Reader 状态未知")
                    return
                @unknown default:
                    os_log(.info, log: Self.sessionLog, "[FramePusher] ⚠️ Reader 状态异常，停止推帧 display=%{public}u", displayID)
                    notifyPusherStopped(reason: "Reader 状态异常")
                    return
                }
            }
        }

        private func pushFrameToExtension(displayID: UInt32, surfaceID: UInt32, pts: CMTime, duration: CMTime) {
            WallpaperExtensionSocketServer.shared.pushFrame(
                displayID: displayID,
                surfaceID: surfaceID,
                pts: pts,
                duration: duration
            )
        }

        private func writePixelBuffer(_ pixelBuffer: CVPixelBuffer, to surface: IOSurface) {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
            let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
            let dstWidth = surface.width
            let dstHeight = surface.height

            surface.lock(options: [], seed: nil)
            defer { surface.unlock(options: [], seed: nil) }

            // 尺寸完全匹配 → 直接内存拷贝
            if srcWidth == dstWidth && srcHeight == dstHeight {
                guard let src = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
                let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let dst = surface.baseAddress
                let dstRowBytes = surface.bytesPerRow
                let copyBytes = min(srcRowBytes, dstRowBytes)
                for y in 0..<dstHeight {
                    memcpy(dst + y * dstRowBytes, src + y * srcRowBytes, copyBytes)
                }
                return
            }

            // 尺寸不匹配 → 缩放
            scalePixelBuffer(pixelBuffer, srcWidth: srcWidth, srcHeight: srcHeight, to: surface, dstWidth: dstWidth, dstHeight: dstHeight)
        }

        /// 将源像素缓冲区缩放后写入目标 IOSurface。
        /// 使用 aspect-fill 保持宽高比：视频填满整个 IOSurface，多余部分裁剪，与扩展端 VideoRenderer 行为一致。
        /// 双缓冲下同一 surface 每 2 帧被写入一次，缓存目标 CGContext 减少逐帧创建开销。
        private func scalePixelBuffer(
            _ src: CVPixelBuffer,
            srcWidth: Int,
            srcHeight: Int,
            to surface: IOSurface,
            dstWidth: Int,
            dstHeight: Int
        ) {
            let dstRowBytes = surface.bytesPerRow
            let dstBase = surface.baseAddress

            // 创建源 CGImage（必须逐帧创建，pixel buffer 地址变化）
            guard let srcData = CVPixelBufferGetBaseAddress(src) else { return }
            let srcRowBytes = CVPixelBufferGetBytesPerRow(src)
            let srcColorSpace = CGColorSpaceCreateDeviceRGB()
            let srcBitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
            guard let srcContext = CGContext(
                data: srcData,
                width: srcWidth,
                height: srcHeight,
                bitsPerComponent: 8,
                bytesPerRow: srcRowBytes,
                space: srcColorSpace,
                bitmapInfo: srcBitmapInfo.rawValue
            ), let srcImage = srcContext.makeImage() else { return }

            // 目标 CGContext：同一 surface 且尺寸不变则复用
            let dstContext: CGContext
            if let lastSurface = lastDstSurface, lastSurface === surface,
               let cached = lastDstContext, cached.width == dstWidth, cached.height == dstHeight {
                dstContext = cached
            } else {
                let dstBitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
                guard let ctx = CGContext(
                    data: dstBase,
                    width: dstWidth,
                    height: dstHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: dstRowBytes,
                    space: srcColorSpace,
                    bitmapInfo: dstBitmapInfo.rawValue
                ) else { return }
                lastDstSurface = surface
                lastDstContext = ctx
                dstContext = ctx
            }

            // 缩放绘制 — 按 CropLayout：letterbox 填色 + viewport 内 aspect-fill 裁切框。
            // shouldApplyCrop=false 时回现状 aspect-fill（与扩展端 VideoRenderer 行为一致）。
            dstContext.interpolationQuality = .medium
            let settings = DisplayCropSettingsStore.sharedSettings(forDisplayID: displayID)
            if settings.shouldApplyCrop {
                let layout = CropLayoutEngine.compute(
                    wallpaperSize: CGSize(width: srcWidth, height: srcHeight),
                    screenSize: CGSize(width: dstWidth, height: dstHeight),
                    settings: settings)

                // 1. 整个目标填 letterbox 色
                dstContext.setFillColor(layout.letterboxColor)
                dstContext.fill(CGRect(x: 0, y: 0, width: dstWidth, height: dstHeight))

                // 2. viewport 像素矩形（CGContext 默认 y 向下，与 CropLayout 一致）
                let vpX = layout.viewportRect.x * Double(dstWidth)
                let vpY = layout.viewportRect.y * Double(dstHeight)
                let vpW = layout.viewportRect.w * Double(dstWidth)
                let vpH = layout.viewportRect.h * Double(dstHeight)

                // 3. 源裁切框像素
                let cropX = Int(layout.wallpaperCropRect.x * Double(srcWidth))
                let cropY = Int(layout.wallpaperCropRect.y * Double(srcHeight))
                let cropW = max(1, Int(layout.wallpaperCropRect.w * Double(srcWidth)))
                let cropH = max(1, Int(layout.wallpaperCropRect.h * Double(srcHeight)))

                // 4. 在 viewport 内 aspect-fill 绘制裁切后的源
                let srcAspect = Double(cropW) / Double(cropH)
                let vpAspect = vpW / max(1, vpH)
                let drawW: Double, drawH: Double, drawX: Double, drawY: Double
                if srcAspect > vpAspect {
                    drawH = vpH
                    drawW = vpH * srcAspect
                    drawX = vpX + (vpW - drawW) / 2
                    drawY = vpY
                } else {
                    drawW = vpW
                    drawH = vpW / srcAspect
                    drawX = vpX
                    drawY = vpY + (vpH - drawH) / 2
                }
                if let cropped = srcImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) {
                    dstContext.draw(cropped, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
                } else {
                    dstContext.draw(srcImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
                }
            } else {
                // 现状 aspect-fill：保持宽高比，填满目标，裁剪溢出
                let srcAspect = Double(srcWidth) / Double(srcHeight)
                let dstAspect = Double(dstWidth) / Double(dstHeight)
                let drawRect: CGRect
                if srcAspect > dstAspect {
                    // 源更宽 → 按高度填满，宽度裁剪左右
                    let drawWidth = Int(Double(dstHeight) * srcAspect)
                    let drawX = (dstWidth - drawWidth) / 2
                    drawRect = CGRect(x: drawX, y: 0, width: drawWidth, height: dstHeight)
                } else {
                    // 源更高或相等 → 按宽度填满，高度裁剪上下
                    let drawHeight = Int(Double(dstWidth) / srcAspect)
                    let drawY = (dstHeight - drawHeight) / 2
                    drawRect = CGRect(x: 0, y: drawY, width: dstWidth, height: drawHeight)
                }
                dstContext.draw(srcImage, in: drawRect)
            }
        }
    }
}
