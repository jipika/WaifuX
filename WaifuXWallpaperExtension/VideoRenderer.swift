//  AVSampleBufferDisplayLayer 视频渲染器
//
//  AVPlayerLayer 在远程 CAContext 中无法工作（DisplaySize 保持 0x0），
//  因此我们手动渲染帧 — 与 Apple 的 VideoPlayer 做法一致。
//
//  循环播放是无缝的：在每个循环边界，新样本的 DTS 和 PTS 都会偏移以继续时间线。
//  这避免了刷新渲染器（会丢弃缓冲帧并导致可见卡顿）。
//
//  严格参照 Phosphene (MIT) 的实现。

@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics

final class VideoRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let rootLayer: CALayer
    private let backgroundFrameLayer: CALayer
    private let stillFrameLayer: CALayer
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    private var isRunning = true
    private(set) var isPaused = false
    private var currentPolicy: PlaybackPolicy = .full
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?

    /// 该渲染器所属的 displayID，用于读取 App Group 里的可视区域 crop 配置。
    private let displayID: UInt32

    // 无缝循环状态
    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero

    /// 在每个循环边界调用，选择下一轮迭代的视频 URL。
    /// 用于自适应播放（根据策略切换 FPS 变体）。
    var variantSelector: (() -> URL)?

    static func create(rootLayer: CALayer, videoURL: URL, displayID: UInt32) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }

        let videoSize = await Self.displaySize(for: track)

        // CALayer / AVSampleBufferDisplayLayer 创建与 addSublayer 必须在主线程：
        // 历史上整个 init 在 acquire 的非主线程 Task 上执行，会触发 Quartz thread-checker
        // 警告，且远程 CAContext 下偶发渲染管线无帧输出。
        return await MainActor.run {
            let bounds = rootLayer.bounds
            let layout = Self.aspectFillLayout(videoSize: videoSize, in: bounds)

            extLog("[VideoRenderer] video=\(Int(videoSize.width))x\(Int(videoSize.height)) display=\(Int(bounds.width))x\(Int(bounds.height)) fillScale=\(layout.scale)")

            let displayLayer = AVSampleBufferDisplayLayer()
            displayLayer.videoGravity = .resizeAspectFill
            displayLayer.frame = layout.frame
            displayLayer.contentsScale = rootLayer.contentsScale

            return VideoRenderer(
                rootLayer: rootLayer,
                displayLayer: displayLayer,
                asset: asset,
                videoTrack: track,
                fillFrame: layout.frame,
                displayID: displayID
            )
        }
    }

    private init(rootLayer: CALayer, displayLayer: AVSampleBufferDisplayLayer, asset: AVURLAsset, videoTrack: AVAssetTrack, fillFrame: CGRect, displayID: UInt32) {
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        self.rootLayer = rootLayer
        self.asset = asset
        self.videoTrack = videoTrack
        self.displayID = displayID
        self.backgroundFrameLayer = CALayer()
        self.stillFrameLayer = CALayer()

        // 裁剪 displayLayer 超出 rootLayer 边界的部分（fillFrame 在宽高比不一致时会超出 rootLayer.bounds）
        rootLayer.masksToBounds = true

        backgroundFrameLayer.frame = rootLayer.bounds
        backgroundFrameLayer.contentsGravity = .resizeAspectFill
        backgroundFrameLayer.contentsScale = rootLayer.contentsScale
        // 即时占位底图：generateBackgroundFrame 是异步的（AVAssetImageGenerator），
        // 期间如果 acquire 后立即被 recomputeAndApplyPolicy() 拉到 .paused（锁屏 /
        // alwaysPauseDesktop / userPaused 等），displayLayer 还没机会渲染第一帧 →
        // backgroundFrameLayer.opacity=0 → 桌面看到的是黑屏，没有底图可见。
        // 用 BMP 缓存（上次会话写入的当前视频快照）做即时兜底，避免暂停态启动黑屏。
        // 异步 generateBackgroundFrame 完成后会用更高质量的视频封面覆盖 contents。
        if let cachedBMP = loadCachedSnapshotImage() {
            backgroundFrameLayer.contents = cachedBMP
            backgroundFrameLayer.opacity = 1
        } else {
            backgroundFrameLayer.opacity = 0
        }
        rootLayer.addSublayer(backgroundFrameLayer)

        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        displayLayer.isOpaque = false
        rootLayer.addSublayer(displayLayer)

        stillFrameLayer.frame = rootLayer.bounds
        stillFrameLayer.contentsGravity = .resizeAspectFill
        stillFrameLayer.contentsScale = rootLayer.contentsScale
        stillFrameLayer.opacity = 0
        rootLayer.addSublayer(stillFrameLayer)

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase

        // 即时同步底图：如果 BMP 缓存为空（首次启动 / 清理后），同步提取视频首帧
        // 作为 backgroundFrameLayer 内容，避免锁屏 acquire 后黑屏。
        // 异步 generateBackgroundFrame 完成后会用更高质量封面覆盖。
        if backgroundFrameLayer.contents == nil {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                backgroundFrameLayer.contents = cgImage
                backgroundFrameLayer.opacity = 1
                extLog("  [Renderer] 同步首帧底图已设置: \(asset.url.lastPathComponent)")
            }
        }
        generateBackgroundFrame(for: asset)
    }

    private static func displaySize(for track: AVAssetTrack) async -> CGSize {
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        let transformedSize = naturalSize.applying(preferredTransform)
        let videoWidth = max(1, abs(transformedSize.width))
        let videoHeight = max(1, abs(transformedSize.height))
        return CGSize(width: videoWidth, height: videoHeight)
    }

    private static func displaySizeSync(for track: AVAssetTrack) -> CGSize {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value = CGSize.zero }
        let box = Box()
        DispatchQueue.global().async {
            Task {
                box.value = await displaySize(for: track)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value
    }

    private static func aspectFillLayout(videoSize: CGSize, in bounds: CGRect) -> (frame: CGRect, scale: CGFloat) {
        let videoWidth = max(1, videoSize.width)
        let videoHeight = max(1, videoSize.height)
        let fillScale = max(bounds.width / videoWidth, bounds.height / videoHeight)
        let fillFrame = CGRect(
            x: (bounds.width - videoWidth * fillScale) / 2,
            y: (bounds.height - videoHeight * fillScale) / 2,
            width: videoWidth * fillScale,
            height: videoHeight * fillScale
        )
        return (fillFrame, fillScale)
    }

    private func applyAspectFillLayout(for track: AVAssetTrack) {
        let videoSize = Self.displaySizeSync(for: track)
        if Thread.isMainThread {
            applyAspectFillLayout(videoSize: videoSize)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyAspectFillLayout(videoSize: videoSize)
            }
        }
    }

    func relayoutForCurrentDisplayGeometry() {
        applyAspectFillLayout(for: videoTrack)
    }

    private func applyAspectFillLayout(videoSize: CGSize) {
        let bounds = rootLayer.bounds
        rootLayer.masksToBounds = true
        let settings = ExtCropPrefs.settings(forDisplayID: displayID)

        if settings.shouldApplyCrop {
            let layout = ExtCropEngine.compute(
                wallpaperSize: videoSize, screenSize: bounds.size, settings: settings)
            let geometry = ExtCropGeometry.layerGeometry(layout: layout, in: bounds)
            rootLayer.backgroundColor = layout.letterboxColor
            // contentsRect 在远程 CAContext + AVSampleBufferDisplayLayer 路径中
            // 不能可靠地表达“先裁切、再等比例铺满”。若配合 .resize，
            // 竖屏会把整张横屏帧直接压进窄 viewport。改用超出 root bounds 的
            // videoFrame，并由 rootLayer.masksToBounds 完成真实裁切。
            displayLayer.frame = geometry.videoFrame
            displayLayer.videoGravity = .resizeAspectFill
            displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            displayLayer.contentsScale = rootLayer.contentsScale
            backgroundFrameLayer.frame = geometry.videoFrame
            backgroundFrameLayer.contentsGravity = .resizeAspectFill
            backgroundFrameLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            stillFrameLayer.frame = geometry.videoFrame
            stillFrameLayer.contentsGravity = .resizeAspectFill
            stillFrameLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            stillFrameLayer.contentsScale = rootLayer.contentsScale
            extLog(
                "[VideoRenderer] layout crop video=\(Int(videoSize.width))x\(Int(videoSize.height)) "
                    + "display=\(Int(bounds.width))x\(Int(bounds.height)) "
                    + "frame=\(Int(geometry.videoFrame.width))x\(Int(geometry.videoFrame.height))"
            )
        } else {
            // 现状 aspect-fill
            rootLayer.backgroundColor = nil
            let fill = Self.aspectFillLayout(videoSize: videoSize, in: bounds)
            backgroundFrameLayer.frame = bounds
            displayLayer.frame = fill.frame
            displayLayer.videoGravity = .resizeAspectFill
            displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            displayLayer.contentsScale = rootLayer.contentsScale
            backgroundFrameLayer.contentsGravity = .resizeAspectFill
            backgroundFrameLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            stillFrameLayer.frame = bounds
            stillFrameLayer.contentsGravity = .resizeAspectFill
            stillFrameLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            stillFrameLayer.contentsScale = rootLayer.contentsScale
            extLog("[VideoRenderer] layout updated video=\(Int(videoSize.width))x\(Int(videoSize.height)) display=\(Int(bounds.width))x\(Int(bounds.height)) fillScale=\(fill.scale)")
        }
    }

    // MARK: - Playback Control

    func start() {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        // 在第一次入队前重置 timebase，使帧不会被视为迟到
        CMTimebaseSetTime(timebase, time: .zero)

        if let firstSample = output.copyNextSampleBuffer() {
            renderer.enqueue(firstSample)
        }

        currentReader = reader
        currentOutput = output
        ptsOffset = .zero
        lastEnqueuedEnd = .zero

        // 开始推进 timebase — 播放开始
        CMTimebaseSetRate(timebase, rate: 1.0)

        prepareNextReader()
        feedFromCurrentReader()
    }

    func stop() {
        cancelDeepPauseTimer()
        queue.sync {
            isRunning = false
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
        }
        DispatchQueue.main.async { [displayLayer, backgroundFrameLayer, stillFrameLayer] in
            displayLayer.removeFromSuperlayer()
            backgroundFrameLayer.removeFromSuperlayer()
            stillFrameLayer.removeFromSuperlayer()
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        generateStillFrame()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0
        if currentReader == nil {
            // 从深度暂停中唤醒 — reader 已被释放，重建前先恢复
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                recreatePlayback()
                CMTimebaseSetRate(timebase, rate: 1.0)
            }
        } else {
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }

    /// 显示器经过长时间睡眠后，AVSampleBufferVideoRenderer 可能仍保留一个失效的
    /// 解码会话；仅恢复 timebase 不会再次产出帧。重建 reader 和渲染队列，保留当前
    /// 暂停状态，使锁屏和桌面在唤醒后都能重新提交首帧。
    func recoverFromDisplayWake() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.cancelRamp()
            self.cancelDeepPauseTimer()
            self.recreatePlayback()
            CMTimebaseSetRate(self.timebase, rate: self.isPaused ? 0.0 : 1.0)
            extLog("  [Renderer] 显示器唤醒后已重建解码管线")
        }
    }

    /// 热切换视频文件。保留当前 CAContext/layer，只替换视频源。
    func replaceVideo(with videoURL: URL) {
        let newAsset = AVURLAsset(url: videoURL)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let track = try? await newAsset.loadTracks(withMediaType: .video).first else {
                extLog("[Renderer] ❌ 新视频无轨道: \(videoURL.lastPathComponent)")
                return
            }
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                // 停止当前管线，切换到新视频
                renderer.stopRequestingMediaData()
                renderer.flush()
                currentReader?.cancelReading()
                nextReader?.cancelReading()
                asset = newAsset
                videoTrack = track
                applyAspectFillLayout(for: track)
                generateBackgroundFrame(for: newAsset)
                ptsOffset = .zero
                lastEnqueuedEnd = .zero
                CMTimebaseSetTime(timebase, time: .zero)
                recreatePlayback()
                CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)

                // 暂停态（如 alwaysPauseDesktop）下 stillFrameLayer 仍贴着上一个视频的
                // 静帧 —— pause() 抓的是当时的 asset。如果不主动刷新，桌面会一直看见
                // 老壁纸的画面，直到下次 pause/resume（锁屏 ↔ 解锁）才被冲掉。
                // 这正是 "切换壁纸后必须锁一下屏才生效 / 退出 App 也能恢复" 的根因。
                // 立即把老静帧藏掉露出新视频第一帧，并用新 asset 异步重生静帧。
                if isPaused {
                    DispatchQueue.main.async { [weak self] in
                        self?.stillFrameLayer.opacity = 0
                    }
                    generateStillFrame()
                }

                extLog("[Renderer] ✅ 热切换视频: \(newAsset.url.lastPathComponent)")
            }
        }
    }

    // MARK: - Policy

    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        guard policy != currentPolicy else { return }
        let oldPolicy = currentPolicy
        currentPolicy = policy
        cancelRamp()

        switch policy {
        case .paused:
            if animated {
                rampDown()
            } else {
                pause()
            }
        case .full, .reduced, .minimal:
            if animated, oldPolicy == .paused {
                rampUp()
            } else {
                resume()
            }
        }
    }

    // MARK: - Ramp（类 Apple 锁屏过渡动画）

    private static let rampDuration: TimeInterval = 2.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    /// 缓入缓出三次方：平滑加速然后减速。
    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5
            ? 4.0 * t * t * t
            : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    /// 逐步降低 timebase 速率到零，然后冻结。
    /// 使用平滑缓入曲线使减速看起来自然。
    private func rampDown() {
        guard !isPaused else { return }
        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            // 缓入：慢开始，快结束 → rate 开始时下降缓慢
            let eased = Self.easeInOut(progress)
            let rate = max(1.0 - eased, 0.0)
            CMTimebaseSetRate(self.timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
                self.isPaused = true
                self.generateStillFrame()
                self.scheduleDeepPause()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    /// 逐步将 timebase 速率从零提升到 1.0。
    /// 使用平滑缓出曲线使加速看起来自然。
    private func rampUp() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0

        if currentReader == nil {
            // 深度暂停：没有帧可用于 ramp。立即唤醒而不是对空管道运行 2 秒 ramp。
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                recreatePlayback()
                CMTimebaseSetRate(timebase, rate: 1.0)
            }
            return
        }

        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        // 立即启动，避免速率为 0 时出现死帧
        CMTimebaseSetRate(timebase, rate: 0.01)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeInOut(progress)
            let rate = min(eased, 1.0)
            CMTimebaseSetRate(self.timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
            }
        }
        rampTimer = timer
        timer.resume()
    }

    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    // MARK: - Deep Pause（深度暂停）
    //
    // 持续暂停后（锁屏过夜、亮度为零等），asset reader 仍然持有解码缓冲区和底层
    // 视频解码器。拆除它们可以释放内存并让系统完全空闲。
    // 恢复时通过 `recreatePlayback()` 从头重建管线。

    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            self?.enterDeepPause()
        }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    /// 在渲染队列上运行，当深度暂停计时器触发时调用。
    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, isPaused, currentReader != nil else { return }
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        extLog("  [Renderer] 深度暂停 — 已释放 asset reader")
    }

    /// 在渲染队列上从头重建播放管线。由深度暂停唤醒和错误恢复路径使用。
    /// 从零重启时间线 — 调用者负责恢复 timebase 速率。
    private func recreatePlayback() {
        renderer.stopRequestingMediaData()
        renderer.flush()
        ptsOffset = .zero
        lastEnqueuedEnd = .zero
        CMTimebaseSetTime(timebase, time: .zero)

        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        guard let reader = try? AVAssetReader(asset: asset) else {
            extLog("  [Renderer] 重建时创建 reader 失败 — 启用 BMP 底图兜底")
            currentReader = nil
            currentOutput = nil
            // R6 兜底：唤醒/恢复失败时用缓存 BMP 代替黑屏
            if let bmp = loadCachedSnapshotImage() {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.backgroundFrameLayer.contents = bmp
                    self.backgroundFrameLayer.opacity = 1
                    extLog("  [Renderer] 已回退到缓存 BMP 底图")
                }
            }
            return
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        currentReader = reader
        currentOutput = output

        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Preloaded Loop Reader（预加载循环读取器）

    private func prepareNextReader() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }

            let nextURL = variantSelector?()
            if let nextURL, nextURL != asset.url {
                let newAsset = AVURLAsset(url: nextURL)
                Task.detached { @Sendable [weak self] in
                    guard let self else { return }
                    guard let track = try? await newAsset.loadTracks(withMediaType: .video).first else {
                        extLog("  [Renderer] 变体无视频轨道: \(nextURL.lastPathComponent)")
                        return
                    }
                    nonisolated(unsafe) let loadedTrack = track
                    queue.async { [weak self] in
                        guard let self, isRunning else { return }
                        installNextReader(asset: newAsset, track: loadedTrack)
                    }
                }
            } else {
                installNextReader(asset: asset, track: videoTrack)
            }
        }
    }

    /// 在渲染队列上构建 asset reader 并存储为预加载的 next reader。
    /// 必须在 `queue` 上运行。
    private func installNextReader(asset: AVURLAsset, track: AVAssetTrack) {
        guard let reader = try? AVAssetReader(asset: asset) else {
            extLog("  [Renderer] 无法创建 next reader")
            return
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        nextReader = reader
        nextOutput = output
    }

    /// 在循环边界处交换到预加载的 next reader。
    /// 使用时间偏移实现无缝继续 — 无需 flush，无需重置 timebase。
    private func swapToNextReader() {
        renderer.stopRequestingMediaData()

        // 推进偏移，使下一轮的 DTS/PTS 继续时间线
        ptsOffset = lastEnqueuedEnd

        if let nr = nextReader, let no = nextOutput {
            if let nrAsset = nr.asset as? AVURLAsset, nrAsset.url != asset.url {
                asset = nrAsset
                videoTrack = no.track
                applyAspectFillLayout(for: no.track)
                extLog("  [Renderer] 已切换变体: \(nrAsset.url.lastPathComponent)")
            }
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
        } else {
            extLog("  [Renderer] Next reader 未就绪，同步创建")
            guard let reader = try? AVAssetReader(asset: asset) else {
                extLog("  [Renderer] 无法创建回退 reader")
                return
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            currentReader = reader
            currentOutput = output
        }

        currentReader?.startReading()

        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Playback Loop（播放循环）

    private func feedFromCurrentReader() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning else {
                self?.renderer.stopRequestingMediaData()
                return
            }

            // 不可恢复的失败 — 完全重置
            // 异步调度：requestMediaDataWhenReady 不可重入
            if renderer.status == .failed {
                extLog("  [Renderer] 状态失败: \(renderer.error?.localizedDescription ?? "unknown")，恢复中")
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in
                    self?.recoverFromError()
                }
                return
            }

            // 解码器遇到不连续或错误 — flush 并继续供应
            if renderer.requiresFlushToResumeDecoding {
                renderer.flush()
            }

            while renderer.isReadyForMoreMediaData {
                if let sample = currentOutput?.copyNextSampleBuffer() {
                    let adjusted = offsetTimingForLoop(sample)

                    // 跟踪最高结束时间（max 处理 B 帧重排序）
                    // 某些容器会发出带有无效 PTS 的填充样本 — 跳过它们以防止
                    // NaN 污染时间线偏移
                    let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                    let dur = CMSampleBufferGetDuration(adjusted)
                    if pts.isValid {
                        let sampleEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                        if sampleEnd > lastEnqueuedEnd {
                            lastEnqueuedEnd = sampleEnd
                        }
                    }

                    renderer.enqueue(adjusted)
                } else {
                    // 异步调度：requestMediaDataWhenReady 不可重入
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in
                        self?.swapToNextReader()
                    }
                    return
                }
            }
        }
    }

    /// 偏移样本的 DTS 和 PTS 以实现无缝循环。
    /// 第一轮返回原始样本（无需复制）。
    /// 后续轮创建轻量级副本并调整时间（共享底层数据缓冲区 — 仅时间元数据不同）。
    private func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)

        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted
        )

        return adjusted ?? sample
    }

    /// 在解码器错误后从头重置并重新开始播放。
    private func recoverFromError() {
        recreatePlayback()
        CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
    }

    // MARK: - Background Frame（底图）

    private func generateBackgroundFrame(for sourceAsset: AVURLAsset) {
        Task.detached(priority: .utility) { [weak self] in
            let generator = AVAssetImageGenerator(asset: sourceAsset)
            generator.appliesPreferredTrackTransform = true

            guard let cgImage = try? await generator.image(at: .zero).image else {
                extLog("  [Renderer] 底图封面生成失败")
                return
            }

            DispatchQueue.main.async {
                guard let self, self.asset.url == sourceAsset.url else { return }
                self.backgroundFrameLayer.contents = cgImage
                self.backgroundFrameLayer.opacity = 1
                extLog("  [Renderer] 底图封面已渲染: \(sourceAsset.url.lastPathComponent)")
            }
        }
    }

    // MARK: - Still Frame（静帧）

    private func generateStillFrame() {
        let captureTime = CMTimebaseGetTime(timebase)
        let currentAsset = asset

        Task.detached(priority: .userInitiated) { [weak self] in
            let generator = AVAssetImageGenerator(asset: currentAsset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true

            guard let (cgImage, _) = try? await generator.image(at: captureTime) else {
                extLog("  [Renderer] 静帧生成失败")
                return
            }

            DispatchQueue.main.async {
                guard let self, self.isPaused else { return }
                self.stillFrameLayer.contents = cgImage
                self.stillFrameLayer.opacity = 1
            }
        }
    }
}
