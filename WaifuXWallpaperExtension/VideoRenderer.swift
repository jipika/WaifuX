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
    private let viewportLayer = CALayer()
    private let backgroundFrameLayer: CALayer
    private let stillFrameLayer: CALayer
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    private var isRunning = true
    // This lock covers ONLY source evidence / pause intent. Never wait for the
    // render queue or MainActor while holding it. Layer writes stay on main.
    private let sourceFrameLock = NSLock()
    private var sourceFrameReadiness = VideoSourceFrameReadiness()
    private(set) var isPaused: Bool {
        get { sourceFrameLock.withLock { sourceFrameReadiness.isPaused } }
        set { sourceFrameLock.withLock { sourceFrameReadiness.isPaused = newValue } }
    }
    private var readyForDisplayObserver: (any NSObjectProtocol)?
    private var primeMedia: VideoSourceFrameReadiness.MediaToken?
    private var primeExpiry: DispatchWorkItem?
    private var primeDeadline: DispatchTime?
    private var primeSampleCount = 0
    private struct MediaReset: Sendable {
        let media: VideoSourceFrameReadiness.MediaToken
        let generation: UInt64
        let isPrime: Bool
    }
    private var imageRemovalInFlight = false
    private var pendingMediaReset: MediaReset?
    private static let maximumPrimeSamples = 8
    private static let primeTimeout: TimeInterval = 2
    private var currentPolicy: PlaybackPolicy = .full
    private var rampGeneration: UInt64 = 0
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryPolicy = VideoPlaybackRecoveryPolicy()
    private var playbackGeneration: UInt64 = 0
    private var readerHasDeliveredFrame = false
    private var hasStarted = false
    private var preloadTask: Task<Void, Never>?
    private var replacementTask: Task<Void, Never>?
    private var replacementGeneration: UInt64 = 0
    private let imageTaskLock = NSLock()
    private var backgroundImageTask: Task<Void, Never>?
    private var stillImageTask: Task<Void, Never>?
    private var backgroundImageGeneration: UInt64 = 0
    private var stillImageGeneration: UInt64 = 0
    /// 热切换期间的换源遮片：新视频首帧直接盖在 displayLayer 之上，
    /// 用户点下去就能看到新壁纸，而不是继续盯着上一张等 reader 链跑完。
    /// 它不参与 VideoSourceFrameReadiness 的就绪证据（那套只认真实视频层），
    /// 真实帧 reveal 后自动移除。
    private let replacementCoverLayer = CALayer()
    private var coverImageGeneration: UInt64 = 0
    private var coverImageTask: Task<Void, Never>?

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?

    /// 该渲染器所属的 displayID，用于读取 App Group 里的可视区域 crop 配置。
    // 仅在主线程读取/更新布局状态，几何刷新不再同步等待 AVAssetTrack 加载。
    private var displayID: UInt32
    private var layoutVideoSize: CGSize

    // 无缝循环状态
    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero

    /// 在每个循环边界调用，选择下一轮迭代的视频 URL。
    /// 用于自适应播放（根据策略切换 FPS 变体）。
    var variantSelector: (() -> URL)?

    static func create(
        rootLayer: CALayer,
        videoURL: URL,
        displayID: UInt32,
        isCurrent: @escaping @Sendable () -> Bool = { true }
    ) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await withTaskCancellationHandler(operation: {
            try await asset.loadTracks(withMediaType: .video)
        }, onCancel: { asset.cancelLoading() })
        try Task.checkCancellation()
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }

        let videoSize = await Self.displaySize(for: track)
        try Task.checkCancellation()
        guard ExtDisplayGeometry.isValid(size: videoSize) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Invalid video dimensions"])
        }

        // CALayer / AVSampleBufferDisplayLayer 创建与 addSublayer 必须在主线程：
        // 历史上整个 init 在 acquire 的非主线程 Task 上执行，会触发 Quartz thread-checker
        // 警告，且远程 CAContext 下偶发渲染管线无帧输出。
        return try await MainActor.run {
            try Task.checkCancellation()
            // Loading may outlive the context's setup generation. Reject it
            // before init attaches layers or removes the previous static image.
            guard isCurrent() else { throw CancellationError() }
            let bounds = rootLayer.bounds
            let layout = Self.aspectFillLayout(videoSize: videoSize, in: bounds)

            extLogAggregated(key: "renderer.layout", interval: 60,
                             "[VideoRenderer] video=\(Int(videoSize.width))x\(Int(videoSize.height)) display=\(Int(bounds.width))x\(Int(bounds.height)) fillScale=\(layout.scale)")

            let displayLayer = AVSampleBufferDisplayLayer()
            displayLayer.videoGravity = .resizeAspectFill
            displayLayer.frame = layout.frame
            displayLayer.contentsScale = rootLayer.contentsScale

            return VideoRenderer(
                rootLayer: rootLayer,
                displayLayer: displayLayer,
                asset: asset,
                videoTrack: track,
                videoSize: videoSize,
                displayID: displayID
            )
        }
    }

    private init(rootLayer: CALayer, displayLayer: AVSampleBufferDisplayLayer, asset: AVURLAsset, videoTrack: AVAssetTrack, videoSize: CGSize, displayID: UInt32) {
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        self.rootLayer = rootLayer
        self.asset = asset
        self.videoTrack = videoTrack
        self.displayID = displayID
        self.layoutVideoSize = videoSize
        self.backgroundFrameLayer = CALayer()
        self.stillFrameLayer = CALayer()

        // viewport 同时约束视频、底图、暂停帧，固定比例时不会漏到 letterbox 区域。
        rootLayer.masksToBounds = true
        rootLayer.addSublayer(viewportLayer)

        backgroundFrameLayer.frame = rootLayer.bounds
        backgroundFrameLayer.contentsGravity = .resizeAspectFill
        backgroundFrameLayer.contentsScale = rootLayer.contentsScale
        // 即时占位底图：generateBackgroundFrame 是异步的（AVAssetImageGenerator），
        // 期间如果 acquire 后立即被 recomputeAndApplyPolicy() 拉到 .paused（锁屏 /
        // alwaysPauseDesktop / userPaused 等），displayLayer 还没机会渲染第一帧 →
        // backgroundFrameLayer.opacity=0 → 桌面看到的是黑屏，没有底图可见。
        // 用 BMP 缓存（上次会话写入的当前视频快照）做即时兜底，避免暂停态启动黑屏。
        // 异步 generateBackgroundFrame 完成后会用更高质量的视频封面覆盖 contents。
        if let cachedBMP = ExtCropLayers.staticImage(in: rootLayer) ?? loadCachedSnapshotImage() {
            backgroundFrameLayer.contents = cachedBMP
            backgroundFrameLayer.opacity = 1
        } else {
            backgroundFrameLayer.opacity = 0
        }
        viewportLayer.addSublayer(backgroundFrameLayer)

        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        displayLayer.isOpaque = false
        viewportLayer.addSublayer(displayLayer)

        stillFrameLayer.frame = rootLayer.bounds
        stillFrameLayer.contentsGravity = .resizeAspectFill
        stillFrameLayer.contentsScale = rootLayer.contentsScale
        stillFrameLayer.opacity = 0
        viewportLayer.addSublayer(stillFrameLayer)

        // 换源遮片永远在最上层：盖住上一张视频帧，直到新源真实出帧。
        replacementCoverLayer.frame = rootLayer.bounds
        replacementCoverLayer.contentsGravity = .resizeAspectFill
        replacementCoverLayer.contentsScale = rootLayer.contentsScale
        replacementCoverLayer.opacity = 0
        viewportLayer.addSublayer(replacementCoverLayer)
        ExtCropLayers.removeStaticImage(from: rootLayer)
        rootLayer.contents = nil

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase

        // 首帧只走下面可取消的异步任务。同步 copyCGImage 在外置盘阻塞或
        // 损坏视频上会卡住扩展主线程，并与异步封面重复创建解码器。
        // 无 BMP 时先用有预算的系统图占位，动态帧就绪后覆盖。
        if backgroundFrameLayer.contents == nil, let systemImage = SystemFallbackImage.image() {
            backgroundFrameLayer.contents = systemImage
            backgroundFrameLayer.opacity = 1
            extLog("  [Renderer] 无 BMP 缓存，已挂系统桌面图等待异步首帧: \(asset.url.lastPathComponent)")
        }
        let source = sourceFrameReadiness.requestSource(asset.url)!
        sourceFrameReadiness.install(source)
        if #available(macOS 14.4, *) {
            readyForDisplayObserver = NotificationCenter.default.addObserver(
                forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                object: displayLayer, queue: nil
            ) { [weak self] _ in
                // Notifications carry no source identity. Re-read the actual
                // property under the current media token instead of trusting it.
                DispatchQueue.main.async { [weak self] in
                    self?.refreshSourceFrameReadiness()
                }
            }
        }
        applyAspectFillLayout(videoSize: videoSize)
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

    func relayoutForCurrentDisplayGeometry(displayID: UInt32? = nil) {
        // 调用方在主线程；不要在锁屏/唤醒时阻塞主线程等待外置盘视频元数据。
        if let displayID { self.displayID = displayID }
        applyAspectFillLayout(videoSize: layoutVideoSize)
    }

    private func applyAspectFillLayout(videoSize: CGSize) {
        guard viewportLayer.superlayer === rootLayer, ExtDisplayGeometry.isValid(size: videoSize) else { return }
        layoutVideoSize = videoSize
        let bounds = rootLayer.bounds
        let settings = ExtCropPrefs.settings(forDisplayID: displayID)
        displayLayer.videoGravity = .resizeAspectFill
        let changed = ExtCropLayers.apply(
            rootLayer: rootLayer, viewportLayer: viewportLayer,
            contentLayers: [displayLayer, backgroundFrameLayer, stillFrameLayer, replacementCoverLayer],
            sourceSize: videoSize, settings: settings)
        if changed {
            extLog("[VideoRenderer] layout displayID=\(displayID) video=\(Int(videoSize.width))x\(Int(videoSize.height)) display=\(Int(bounds.width))x\(Int(bounds.height)) viewport=\(viewportLayer.frame) frame=\(displayLayer.frame) preset=\(settings.aspectPreset.rawValue)")
        }
    }

    // MARK: - Source frame barrier

    /// URL of the current, installed source request; nil while a replacement
    /// is still loading tracks. Identity only, not readiness evidence.
    var installedSourceURL: URL? {
        sourceFrameLock.withLock {
            guard let source = sourceFrameReadiness.installedSource,
                  sourceFrameReadiness.isInstalled(source) else { return nil }
            return source.url
        }
    }

    /// True means this renderer has installed this requested URL generation,
    /// removed the reused layer's old image, enqueued displayable video media,
    /// and its actual video layer is ready with no foreign still above it.
    /// This is NOT proof that WindowServer has composited/presented the frame.
    /// On macOS before 14.4 the SDK exposes no such readiness evidence: fail closed.
    /// An idle/paused installed source may claim one bounded prime on its first
    /// query; that query returns false and subsequent queries inspect real state.
    @MainActor
    func isSourceFrameReady(for videoURL: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard #available(macOS 14.4, *) else { return false }
        if refreshSourceFrameReadiness(for: videoURL) { return true }
        let source = sourceFrameLock.withLock { sourceFrameReadiness.claimPrime(for: videoURL) }
        if let source {
            queue.async { [weak self] in self?.beginSourceFramePrime(for: source) }
        }
        return false
    }

    @MainActor
    @discardableResult
    private func refreshSourceFrameReadiness(for videoURL: URL? = nil) -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        let result: (Bool, VideoSourceFrameReadiness.MediaToken?) = sourceFrameLock.withLock {
            guard let media = sourceFrameReadiness.media,
                  videoURL == nil || videoURL == media.source.url,
                  sourceFrameReadiness.isCurrentMedia(media) else { return (false, nil) }
            // isReadyForDisplay is explicitly NOT KVO-compliant in the SDK.
            // Re-read it here; notification arrival alone is not readiness.
            let visibleVideoReady = displayLayer.isReadyForDisplay &&
                !displayLayer.isOutputObscuredDueToInsufficientExternalProtection
            if !visibleVideoReady {
                extLogAggregated(key: "source-frame-not-ready", interval: 2,
                    "  [SourceFrame] layer not ready \(sourceFrameReadiness.diagnostic)")
            }
            guard sourceFrameReadiness.observeLayerReady(visibleVideoReady, for: media),
                  sourceFrameReadiness.revealVideo(media) else { return (false, nil) }
            return (sourceFrameReadiness.isReady(for: media.source.url), media)
        }
        if let media = result.1 {
            // Layer mutations stay on MainActor, outside the state lock.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillFrameLayer.opacity = 0
            stillFrameLayer.contents = nil
            clearReplacementCover()
            CATransaction.commit()
            queue.async { [weak self] in
                guard let self, self.isRunning,
                      self.sourceFrameLock.withLock({ self.sourceFrameReadiness.isCurrentMedia(media) }) else { return }
                self.recoveryPolicy.recordSuccessfulFrame()
                self.finishSourceFramePrime(for: media)
            }
        }
        return result.0
    }

    /// Runs only on queue. Do not change pause intent or run the timebase at 1.
    private func beginSourceFramePrime(for source: VideoSourceFrameReadiness.SourceToken) {
        let admitted = sourceFrameLock.withLock {
            sourceFrameReadiness.isInstalled(source) && sourceFrameReadiness.primeInProgress &&
                !sourceFrameReadiness.isReady(for: source.url) &&
                (sourceFrameReadiness.isPaused || !sourceFrameReadiness.playbackStarted)
        }
        guard isRunning, admitted else {
            sourceFrameLock.withLock { sourceFrameReadiness.finishPrime(source) }
            return
        }
        cancelRamp()
        cancelDeepPauseTimer()
        CMTimebaseSetRate(timebase, rate: 0)
        recreatePlayback(primeSource: source)
    }

    /// Stop feeding, release readers, but retain the image in the video layer.
    /// A delayed decode may still become ready; only the real property can prove it.
    private func releasePrimeReaders() {
        renderer.stopRequestingMediaData()
        // stopRequestingMediaData may leave an already queued block. Revoke its
        // feed generation, but keep the media token for the retained video image.
        playbackGeneration &+= 1
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        preloadTask?.cancel()
        preloadTask = nil
    }

    private func finishSourceFramePrime(for media: VideoSourceFrameReadiness.MediaToken) {
        guard primeMedia == media else { return }
        primeExpiry?.cancel()
        primeExpiry = nil
        primeDeadline = nil
        primeMedia = nil
        sourceFrameLock.withLock { sourceFrameReadiness.finishPrime(media.source) }
        guard sourceFrameLock.withLock({ sourceFrameReadiness.isCurrentMedia(media) }) else { return }
        releasePrimeReaders()
        // resume/start may already have superseded this prime. Never re-pause it.
        if isPaused || !hasStarted { CMTimebaseSetRate(timebase, rate: 0) }
    }

    private func primeHasExpired(for media: VideoSourceFrameReadiness.MediaToken) -> Bool {
        guard primeMedia == media, let deadline = primeDeadline else { return false }
        return DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds
    }

    private func cancelSourceFramePrime() {
        primeExpiry?.cancel()
        primeExpiry = nil
        primeDeadline = nil
        if let media = primeMedia {
            sourceFrameLock.withLock { sourceFrameReadiness.finishPrime(media.source) }
        }
        primeMedia = nil
        primeSampleCount = 0
    }

    // MARK: - Playback Control

    func start() {
        queue.async { [weak self] in
            guard let self, self.isRunning, !self.hasStarted else { return }
            self.hasStarted = true
            self.sourceFrameLock.withLock { self.sourceFrameReadiness.playbackStarted = true }
            self.recoveryPolicy.recordSuccessfulFrame()
            // An idle barrier may have primed before start() arrived. Starting
            // while still paused must not discard that one permitted attempt.
            if self.sourceFrameLock.withLock({ self.sourceFrameReadiness.isPaused && self.sourceFrameReadiness.primeClaimed }) {
                return
            }
            self.recreatePlayback(removeDisplayedImage: false)
            CMTimebaseSetRate(self.timebase, rate: self.isPaused ? 0.0 : 1.0)
        }
    }

    func stop() {
        // Revoke readiness before queue.sync or any asynchronous layer cleanup.
        sourceFrameLock.withLock { sourceFrameReadiness.stop() }
        queue.sync {
            isRunning = false
            cancelSourceFramePrime()
            pendingMediaReset = nil
            playbackGeneration &+= 1
            replacementGeneration &+= 1
            cancelRamp()
            cancelDeepPauseTimer()
            recoveryWorkItem?.cancel()
            recoveryWorkItem = nil
            preloadTask?.cancel()
            preloadTask = nil
            replacementTask?.cancel()
            replacementTask = nil
            renderer.stopRequestingMediaData()
            renderer.flush()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
            currentReader = nil
            currentOutput = nil
            nextReader = nil
            nextOutput = nil
            CMTimebaseSetRate(timebase, rate: 0.0)
        }
        cancelImageTasks()
        DispatchQueue.main.async { [self, viewportLayer, displayLayer, backgroundFrameLayer, stillFrameLayer, replacementCoverLayer] in
            if let observer = readyForDisplayObserver {
                NotificationCenter.default.removeObserver(observer)
                readyForDisplayObserver = nil
            }
            clearReplacementCover()
            backgroundFrameLayer.contents = nil
            stillFrameLayer.contents = nil
            displayLayer.removeFromSuperlayer()
            backgroundFrameLayer.removeFromSuperlayer()
            stillFrameLayer.removeFromSuperlayer()
            replacementCoverLayer.removeFromSuperlayer()
            viewportLayer.removeFromSuperlayer()
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        generateStillFrame()
        queue.async { [weak self] in
            guard let self, self.isRunning, self.isPaused else { return }
            self.scheduleDeepPause()
        }
    }

    func resume() {
        isPaused = false
        queue.async { [weak self] in
            guard let self, self.isRunning, !self.isPaused else { return }
            self.cancelDeepPauseTimer()
            // A prime has a deliberately advanced frozen timestamp and no loop
            // preload. Normal resume rebuilds it instead of playing that queue.
            if self.currentReader == nil || self.primeMedia != nil {
                self.recreatePlayback(removeDisplayedImage: false)
            }
            CMTimebaseSetRate(self.timebase, rate: 1.0)
        }
        // Keep a foreign still visible until CURRENT video is actually ready.
        DispatchQueue.main.async { [weak self] in self?.refreshSourceFrameReadiness() }
        scheduleSourceFrameReadinessPolls()
    }

    /// Ready notifications are edge-triggered and not thread-guaranteed. A few
    /// bounded re-reads cover a missed first notification without polling forever.
    private func scheduleSourceFrameReadinessPolls() {
        for attempt in 1...3 {
            queue.asyncAfter(deadline: .now() + Double(attempt) * 0.25) { [weak self] in
                guard let self, self.isRunning else { return }
                DispatchQueue.main.async { [weak self] in self?.refreshSourceFrameReadiness() }
            }
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
            self.recoveryPolicy.recordSuccessfulFrame()
            self.recreatePlayback(removeDisplayedImage: false)
            CMTimebaseSetRate(self.timebase, rate: self.isPaused ? 0.0 : 1.0)
            extLog("  [Renderer] 显示器唤醒后已重建解码管线")
        }
    }

    /// 热切换视频文件。保留当前 CAContext/layer，只替换视频源。
    func replaceVideo(with videoURL: URL) {
        // Do this synchronously, including same-URL replacements. During a slow
        // loadTracks the old layer/still may stay visible, but can never be ready
        // for the newly requested source generation.
        guard let source = sourceFrameLock.withLock({ sourceFrameReadiness.requestSource(videoURL) }) else { return }
        cancelImageTasks()
        // 先挂新源首帧遮片：用户点下去立刻看到新壁纸，旧帧被挡住，
        // 不必等 loadTracks → flush → reader 这一整条链跑完。
        showReplacementCover(for: videoURL)
        queue.async { [weak self] in
            guard let self, self.isRunning,
                  self.sourceFrameLock.withLock({ self.sourceFrameReadiness.isCurrentRequest(source) }) else { return }
            if self.primeMedia != nil { self.releasePrimeReaders() }
            self.cancelSourceFramePrime()
            self.replacementTask?.cancel()
            self.replacementGeneration &+= 1
            let generation = self.replacementGeneration
            let newAsset = AVURLAsset(url: videoURL)
            self.replacementTask = Task.detached(priority: .userInitiated) { [weak self] in
                func restoreInstalledSource(after failure: String) {
                    self?.queue.async { [weak self] in
                        guard let self, self.isRunning, self.replacementGeneration == generation else { return }
                        self.replacementTask = nil
                        // 新源没装上，遮片必须撤掉，否则会一直盖着恢复后的旧视频。
                        DispatchQueue.main.async { [weak self] in self?.clearReplacementCover() }
                        // The pending URL never installed; the previous installed
                        // source is still the media owner. Rebuild it so a failed
                        // load cannot freeze playback or poison later recovery.
                        self.recreatePlayback(removeDisplayedImage: false)
                        CMTimebaseSetRate(self.timebase, rate: self.isPaused ? 0.0 : 1.0)
                        extLog("  [Renderer] ⚠️ 热切换源加载失败，恢复原视频: \(failure)")
                    }
                }
                guard let track = try? await withTaskCancellationHandler(operation: {
                    try await newAsset.loadTracks(withMediaType: .video).first
                }, onCancel: { newAsset.cancelLoading() }), !Task.isCancelled else {
                    restoreInstalledSource(after: "loadTracks")
                    return
                }
                let videoSize = await Self.displaySize(for: track)
                guard !Task.isCancelled, ExtDisplayGeometry.isValid(size: videoSize), let self else {
                    restoreInstalledSource(after: "invalid-size")
                    return
                }
                nonisolated(unsafe) let loadedTrack = track
                self.queue.async { [weak self] in
                    guard let self, self.isRunning, self.replacementGeneration == generation,
                          self.sourceFrameLock.withLock({ self.sourceFrameReadiness.install(source) }) else { return }
                    self.replacementTask = nil
                    self.asset = newAsset
                    self.videoTrack = loadedTrack
                    self.recoveryPolicy.recordSuccessfulFrame()
                    self.cancelImageTasks()
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let installed = self.sourceFrameLock.withLock { self.sourceFrameReadiness.isInstalled(source) }
                        guard installed else { return }
                        self.applyAspectFillLayout(videoSize: videoSize)
                    }
                    self.generateBackgroundFrame(for: newAsset)
                    let pausedPrime = self.sourceFrameLock.withLock {
                        self.sourceFrameReadiness.isPaused ? self.sourceFrameReadiness.claimPrimeForInstalledSource() : nil
                    }
                    self.recreatePlayback(primeSource: pausedPrime)
                    CMTimebaseSetRate(self.timebase, rate: self.isPaused ? 0.0 : 1.0)
                    // Do not hide the old still or substitute a freshly extracted
                    // poster. refreshSourceFrameReadiness reveals real new video.
                    extLog("[Renderer] ✅ 热切换视频已安装: \(newAsset.url.lastPathComponent)")
                }
            }
        }
    }

    // MARK: - Policy

    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        guard policy != currentPolicy else { return }
        let oldPolicy = currentPolicy
        currentPolicy = policy
        queue.async { [weak self] in
            guard let self else { return }
            self.rampGeneration &+= 1
            self.cancelRamp()
        }

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
        queue.async { [weak self] in self?.startRampDown() }
    }

    private func startRampDown() {
        guard isRunning, !isPaused else { return }
        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        let generation = rampGeneration
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning, self.rampGeneration == generation, self.rampTimer === timer else {
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
        isPaused = false
        queue.async { [weak self] in self?.startRampUp() }
        DispatchQueue.main.async { [weak self] in self?.refreshSourceFrameReadiness() }
    }

    private func startRampUp() {
        guard isRunning, !isPaused else { return }
        cancelDeepPauseTimer()

        if currentReader == nil || primeMedia != nil {
            // No useful queue for a ramp after deep pause or a bounded prime.
            recreatePlayback(removeDisplayedImage: false)
            CMTimebaseSetRate(timebase, rate: 1.0)
            return
        }

        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        // 立即启动，避免速率为 0 时出现死帧
        CMTimebaseSetRate(timebase, rate: 0.01)

        let generation = rampGeneration
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning, self.rampGeneration == generation, self.rampTimer === timer else {
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
        if sourceFrameLock.withLock({ sourceFrameReadiness.primeInProgress }) {
            scheduleDeepPause()
            return
        }
        renderer.stopRequestingMediaData()
        playbackGeneration &+= 1
        // This flush intentionally retains the already certified same-source
        // displayed image. No new media is enqueued until a destructive rebuild.
        renderer.flush()
        sourceFrameLock.withLock { sourceFrameReadiness.retainImageForDeepPause() }
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        preloadTask?.cancel()
        preloadTask = nil
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
    private func recreatePlayback(primeSource initialPrime: VideoSourceFrameReadiness.SourceToken? = nil, removeDisplayedImage: Bool = true) {
        var primeSource = initialPrime
        guard isRunning else { return }
        cancelSourceFramePrime()
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        preloadTask?.cancel()
        preloadTask = nil
        playbackGeneration &+= 1
        let generation = playbackGeneration
        readerHasDeliveredFrame = false
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        ptsOffset = .zero
        lastEnqueuedEnd = .zero
        // Paused/idle first-frame preparation needs its own bounded path. If
        // this rebuild did not explicitly claim it, preserve the caller's rate.
        CMTimebaseSetTime(timebase, time: .zero)
        if primeSource == nil {
            let shouldPrime = sourceFrameLock.withLock { () -> Bool in
                guard let source = sourceFrameReadiness.installedSource else { return false }
                return (sourceFrameReadiness.isPaused || !sourceFrameReadiness.playbackStarted)
                    && !sourceFrameReadiness.isReady(for: source.url)
            }
            if shouldPrime {
                sourceFrameLock.withLock { sourceFrameReadiness.finishPrimeRequest() }
                primeSource = sourceFrameLock.withLock { sourceFrameReadiness.claimPrimeForInstalledSource() }
            }
        }
        guard let media = sourceFrameLock.withLock({
            sourceFrameReadiness.beginMedia(requiresImageRemoval: removeDisplayedImage)
        }) else { return }
        if primeSource == media.source {
            primeMedia = media
            primeSampleCount = 0
            let expiry = DispatchWorkItem { [weak self] in
                self?.finishSourceFramePrime(for: media)
            }
            primeExpiry = expiry
            let deadline = DispatchTime.now() + Self.primeTimeout
            primeDeadline = deadline
            queue.asyncAfter(deadline: deadline, execute: expiry)
        }

        if removeDisplayedImage {
            removeOldImage(for: MediaReset(media: media, generation: generation, isPrime: primeSource != nil))
        } else {
            // Same-source recovery keeps the retained frame visible; only new
            // samples will replace it. Do not flash poster or black content.
            sourceFrameLock.withLock { sourceFrameReadiness.didRemoveOldImage(media) }
            installCurrentReader(for: media)
        }
    }

    private func removeOldImage(for reset: MediaReset) {
        guard isRunning, playbackGeneration == reset.generation,
              sourceFrameLock.withLock({ sourceFrameReadiness.isCurrentMedia(reset.media) }) else { return }
        // Coalesce resets while a previous flush is still completing. Otherwise
        // an older physical flush could remove a newer generation's video after
        // it had enqueued, even if its stale completion was correctly ignored.
        if imageRemovalInFlight {
            pendingMediaReset = reset
            return
        }
        imageRemovalInFlight = true
        // SDK AVFoundation.apinotes explicitly imports the selector as
        // flush(removingDisplayedImage:completionHandler:), available macOS 14.
        // Merely flush() preserves the old displayed image/ready flag.
        renderer.flush(removingDisplayedImage: true, completionHandler: { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.imageRemovalInFlight = false
                if let pending = self.pendingMediaReset {
                    self.pendingMediaReset = nil
                    self.removeOldImage(for: pending)
                    return
                }
                guard self.isRunning, self.playbackGeneration == reset.generation,
                      self.sourceFrameLock.withLock({ self.sourceFrameReadiness.didRemoveOldImage(reset.media) }) else { return }
                // A timed-out prime must not start reading from a late flush callback.
                if reset.isPrime, self.primeMedia != reset.media { return }
                self.installCurrentReader(for: reset.media)
            }
        })
    }

    /// Called only AFTER this media generation's remove-displayed-image flush.
    private func installCurrentReader(for media: VideoSourceFrameReadiness.MediaToken) {
        if primeHasExpired(for: media) { finishSourceFramePrime(for: media); return }
        guard let reader = try? AVAssetReader(asset: asset) else {
            extLog("  [Renderer] 重建时创建 reader 失败 — 保留静态底图")
            scheduleRecovery(reason: "创建 reader 失败")
            return
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { scheduleRecovery(reason: "无法添加 reader output"); return }
        reader.add(output)
        currentReader = reader
        currentOutput = output
        guard reader.startReading() else {
            scheduleRecovery(reason: "startReading 失败: \(reader.error?.localizedDescription ?? "unknown")")
            return
        }
        if primeHasExpired(for: media) { finishSourceFramePrime(for: media); return }
        // The one-shot prime never preloads a second decoder/reader or loops.
        if primeMedia == nil { prepareNextReader() }
        feedFromCurrentReader(media: media)
    }

    // MARK: - Preloaded Loop Reader（预加载循环读取器）

    private func prepareNextReader() {
        let generation = playbackGeneration
        queue.async { [weak self] in
            guard let self, isRunning, playbackGeneration == generation else { return }

            let nextURL = variantSelector?()
            if let nextURL, nextURL != asset.url {
                let newAsset = AVURLAsset(url: nextURL)
                preloadTask?.cancel()
                preloadTask = Task.detached { @Sendable [weak self] in
                    guard let track = try? await withTaskCancellationHandler(operation: {
                        try await newAsset.loadTracks(withMediaType: .video).first
                    }, onCancel: { newAsset.cancelLoading() }), !Task.isCancelled else {
                        extLog("  [Renderer] 变体无视频轨道: \(nextURL.lastPathComponent)")
                        return
                    }
                    guard let self else { return }
                    nonisolated(unsafe) let loadedTrack = track
                    queue.async { [weak self] in
                        guard let self, isRunning, playbackGeneration == generation else { return }
                        preloadTask = nil
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
        guard reader.canAdd(output) else { return }
        reader.add(output)
        nextReader = reader
        nextOutput = output
    }

    /// 在循环边界处交换到预加载的 next reader。
    /// 使用时间偏移实现无缝继续 — 无需 flush，无需重置 timebase。
    private func swapToNextReader() {
        guard isRunning else { return }
        renderer.stopRequestingMediaData()
        playbackGeneration &+= 1
        preloadTask?.cancel()
        preloadTask = nil
        readerHasDeliveredFrame = false

        // 推进偏移，使下一轮的 DTS/PTS 继续时间线
        ptsOffset = lastEnqueuedEnd

        if let nr = nextReader, let no = nextOutput {
            if let nrAsset = nr.asset as? AVURLAsset, nrAsset.url != asset.url {
                // A different URL is a different source, not proof for the old
                // URL. Unlike same-source loops it needs an image-removing reset.
                guard let source = sourceFrameLock.withLock({ sourceFrameReadiness.requestSource(nrAsset.url) }),
                      sourceFrameLock.withLock({ sourceFrameReadiness.install(source) }) else { return }
                cancelImageTasks()
                asset = nrAsset
                videoTrack = no.track
                applyAspectFillLayout(for: no.track)
                generateBackgroundFrame(for: nrAsset)
                recreatePlayback()
                CMTimebaseSetRate(timebase, rate: isPaused ? 0 : 1)
                extLog("  [Renderer] 已切换变体: \(nrAsset.url.lastPathComponent)")
                return
            }
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
        } else {
            extLog("  [Renderer] Next reader 未就绪，同步创建")
            guard let reader = try? AVAssetReader(asset: asset) else {
                extLog("  [Renderer] 无法创建回退 reader")
                scheduleRecovery(reason: "创建循环 reader 失败")
                return
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { scheduleRecovery(reason: "无法添加循环 output"); return }
            reader.add(output)
            currentReader = reader
            currentOutput = output
        }

        guard currentReader?.startReading() == true else {
            scheduleRecovery(reason: "循环 startReading 失败: \(currentReader?.error?.localizedDescription ?? "unknown")")
            return
        }

        prepareNextReader()
        if let media = sourceFrameLock.withLock({ sourceFrameReadiness.media }) {
            feedFromCurrentReader(media: media)
        }
    }

    // MARK: - Playback Loop（播放循环）

    private func feedFromCurrentReader(media: VideoSourceFrameReadiness.MediaToken) {
        let generation = playbackGeneration
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning else {
                self?.renderer.stopRequestingMediaData()
                return
            }
            guard playbackGeneration == generation else { return }
            guard sourceFrameLock.withLock({ sourceFrameReadiness.isCurrentMedia(media) }) else {
                renderer.stopRequestingMediaData()
                return
            }

            // 不可恢复的失败 — 完全重置
            // 异步调度：requestMediaDataWhenReady 不可重入
            if renderer.status == .failed {
                extLog("  [Renderer] 状态失败: \(renderer.error?.localizedDescription ?? "unknown")，恢复中")
                scheduleRecovery(reason: "解码器失败: \(renderer.error?.localizedDescription ?? "unknown")")
                return
            }

            // A flush must invalidate media evidence and restart at an IDR.
            if renderer.requiresFlushToResumeDecoding {
                scheduleRecovery(reason: "解码器要求 flush")
                return
            }

            while renderer.isReadyForMoreMediaData {
                if primeHasExpired(for: media) { finishSourceFramePrime(for: media); return }
                // Backpressure is only a feeding limit, NEVER readiness proof.
                // Only displayable samples consume the budget; a corrupt stream
                // is bounded by the prime deadline instead.
                if primeMedia == media, primeSampleCount >= Self.maximumPrimeSamples {
                    // 预算用完就把这次 prime 结账，别把状态永久停在 priming：
                    // 否则后续 recreatePlayback 会一直看到一个未完成的 prime。
                    finishSourceFramePrime(for: media)
                    return
                }
                if let sample = autoreleasepool(invoking: { currentOutput?.copyNextSampleBuffer() }) {
                    if primeHasExpired(for: media) { finishSourceFramePrime(for: media); return }
                    let adjusted = offsetTimingForLoop(sample)

                    // 跟踪最高结束时间（max 处理 B 帧重排序）
                    // 某些容器会发出带有无效 PTS 的填充样本 — 跳过它们以防止
                    // NaN 污染时间线偏移
                    let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                    let dur = CMSampleBufferGetDuration(adjusted)
                    guard pts.isNumeric, pts.seconds.isFinite else { continue }
                    if pts.isNumeric {
                        let sampleEnd = dur.isNumeric && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                        guard sampleEnd.isNumeric else { continue }
                        if sampleEnd > lastEnqueuedEnd {
                            lastEnqueuedEnd = sampleEnd
                        }
                    }

                    if primeMedia == media {
                        // At rate zero, a PTS above the frozen clock would never
                        // become visible. Advance ONLY the frozen timestamp to
                        // cover these bounded samples (including B-frame reorder).
                        CMTimebaseSetRate(timebase, rate: 0)
                        if pts > CMTimebaseGetTime(timebase) { CMTimebaseSetTime(timebase, time: pts) }
                    }
                    let displayable = Self.isDisplayableVideoSample(adjusted)
                    // Only count DISPLAYABLE samples toward the prime budget: a
                    // bake with an open-GOP / non-display prefix must still get
                    // its first real frame within the deadline. The 2s deadline
                    // bounds a genuinely corrupt stream.
                    if primeMedia == media, displayable { primeSampleCount += 1 }
                    let preflight: (isCurrent: Bool, oldImageRemoved: Bool, firstFrameEnqueued: Bool)? =
                        sourceFrameLock.withLock {
                            guard sourceFrameReadiness.isCurrentMedia(media) else { return nil }
                            return (true, sourceFrameReadiness.oldImageRemoved,
                                    sourceFrameReadiness.firstFrameEnqueued)
                        }
                    guard let preflight else {
                        renderer.stopRequestingMediaData()
                        return
                    }
                    guard preflight.oldImageRemoved else {
                        // 旧帧的 flush 还没回来。这不是失败：flush 完成会重新装
                        // reader 并继续喂帧；在这里走 recovery 会先把 rate 归零、
                        // 再等退避重试，表现就是「切了以后要等几秒才变」。
                        renderer.stopRequestingMediaData()
                        return
                    }
                    let firstFrame = !preflight.firstFrameEnqueued
                    renderer.enqueue(adjusted)
                    guard renderer.status != .failed else {
                        if sourceFrameLock.withLock({ sourceFrameReadiness.isCurrentMedia(media) }) {
                            scheduleRecovery(reason: "enqueue 失败")
                        } else {
                            renderer.stopRequestingMediaData()
                        }
                        return
                    }
                    guard sourceFrameLock.withLock({ sourceFrameReadiness.isCurrentMedia(media) }) else {
                        renderer.stopRequestingMediaData()
                        return
                    }
                    if displayable {
                        sourceFrameLock.withLock { sourceFrameReadiness.didEnqueueDisplayableFrame(media) }
                    }
                    let shouldPoll = firstFrame && displayable
                    // Delivery is recorded AFTER enqueue, never before it, and
                    // still does not mean the video layer is ready for display.
                    if displayable { readerHasDeliveredFrame = true }
                    if shouldPoll {
                        DispatchQueue.main.async { [weak self] in self?.refreshSourceFrameReadiness() }
                    }
                } else {
                    // A one-shot prime must not advance to the next loop or retry.
                    if primeMedia == media {
                        releasePrimeReaders()
                        return
                    }
                    // 异步调度：requestMediaDataWhenReady 不可重入
                    renderer.stopRequestingMediaData()
                    guard VideoPlaybackRecoveryPolicy.canContinueLoop(
                        completed: currentReader?.status == .completed,
                        deliveredValidFrame: readerHasDeliveredFrame,
                        timelineAdvanced: lastEnqueuedEnd > ptsOffset
                    ) else {
                        scheduleRecovery(reason: "Reader 未完成有效循环: \(currentReader?.error?.localizedDescription ?? "empty or failed")")
                        return
                    }
                    queue.async { [weak self] in
                        guard let self, self.isRunning, self.playbackGeneration == generation else { return }
                        self.swapToNextReader()
                    }
                    return
                }
            }
        }
    }

    private static func isDisplayableVideoSample(_ sample: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetNumSamples(sample) > 0, CMSampleBufferDataIsReady(sample) else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
              !attachments.isEmpty else { return true }
        return attachments.contains { ($0[kCMSampleAttachmentKey_DoNotDisplay as String] as? Bool) != true }
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
    private func scheduleRecovery(reason: String) {
        guard isRunning, recoveryWorkItem == nil else { return }
        if let media = primeMedia {
            // The query's one bounded attempt cannot turn into the normal
            // recovery retry loop while the user's pause intent is in force.
            finishSourceFramePrime(for: media)
            sourceFrameLock.withLock { sourceFrameReadiness.invalidateMedia() }
            playbackGeneration &+= 1
            extLog("  [Renderer] 首帧 prime 失败，保留暂停/底图: \(reason)")
            return
        }
        sourceFrameLock.withLock { sourceFrameReadiness.invalidateMedia() }
        renderer.stopRequestingMediaData()
        renderer.flush()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        preloadTask?.cancel()
        preloadTask = nil
        playbackGeneration &+= 1
        CMTimebaseSetRate(timebase, rate: 0.0)
        let generation = playbackGeneration
        switch recoveryPolicy.recordFailure() {
        case .stop:
            extLog("  [Renderer] 连续失败超过重试上限，保留静态底图: \(reason)")
        case .retry(let delay):
            extLog("  [Renderer] \(delay)s 后有限重试 (\(recoveryPolicy.consecutiveFailures)): \(reason)")
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning, self.playbackGeneration == generation else { return }
                self.recoveryWorkItem = nil
                self.recreatePlayback(removeDisplayedImage: false)
                // Image-removing flush is asynchronous; currentReader is still
                // nil here even for a healthy rebuild. Restore intent now rather
                // than leaving normal recovery permanently frozen at rate zero.
                CMTimebaseSetRate(self.timebase, rate: self.isPaused ? 0.0 : 1.0)
            }
            recoveryWorkItem = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: - Background Frame（底图）

    private func cancelImageTasks() {
        imageTaskLock.lock()
        backgroundImageGeneration &+= 1
        stillImageGeneration &+= 1
        let background = backgroundImageTask
        let still = stillImageTask
        backgroundImageTask = nil
        stillImageTask = nil
        imageTaskLock.unlock()
        background?.cancel()
        still?.cancel()
    }

    private func generateBackgroundFrame(for sourceAsset: AVURLAsset) {
        guard let source = sourceFrameLock.withLock({ () -> VideoSourceFrameReadiness.SourceToken? in
            guard let source = sourceFrameReadiness.installedSource,
                  source.url == sourceAsset.url, sourceFrameReadiness.isInstalled(source) else { return nil }
            return source
        }) else { return }
        imageTaskLock.lock()
        backgroundImageGeneration &+= 1
        let generation = backgroundImageGeneration
        let oldTask = backgroundImageTask
        backgroundImageTask = nil
        imageTaskLock.unlock()
        oldTask?.cancel()
        let task = Task.detached(priority: .utility) { [weak self] in
            let generator = AVAssetImageGenerator(asset: sourceAsset)
            generator.appliesPreferredTrackTransform = true
            if #available(macOS 15.0, *) { generator.dynamicRangePolicy = .forceSDR }
            generator.maximumSize = CGSize(width: WallpaperSnapshotPixelBudget.maximumVideoImageDimension,
                                           height: WallpaperSnapshotPixelBudget.maximumVideoImageDimension)

            guard let cgImage = try? await withTaskCancellationHandler(operation: {
                try await generator.image(at: .zero).image
            }, onCancel: { generator.cancelAllCGImageGeneration() }), !Task.isCancelled else {
                if Task.isCancelled { return }
                extLog("  [Renderer] 底图封面生成失败")
                return
            }
            guard WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: cgImage.width, height: cgImage.height, bytesPerRow: cgImage.bytesPerRow) else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                self.imageTaskLock.lock()
                let current = self.backgroundImageGeneration == generation
                if current { self.backgroundImageTask = nil }
                self.imageTaskLock.unlock()
                guard current else { return }
                let installed = self.sourceFrameLock.withLock { self.sourceFrameReadiness.isInstalled(source) }
                guard installed else { return }
                self.backgroundFrameLayer.contents = cgImage
                self.backgroundFrameLayer.opacity = 1
                extLog("  [Renderer] 底图封面已渲染: \(sourceAsset.url.lastPathComponent)")
            }
        }
        imageTaskLock.lock()
        let admitted = backgroundImageGeneration == generation
        if admitted { backgroundImageTask = task }
        imageTaskLock.unlock()
        if !admitted { task.cancel() }
    }

    // MARK: - Replacement Cover（换源遮片）

    /// 用户点了新壁纸就立刻把它的首帧盖上去。旧视频帧仍在 displayLayer 里，
    /// 但被这张遮片挡住，直到新源真实出帧（reveal）后移除。
    /// 生成失败时不动遮片：宁可继续显示旧帧，也不要闪黑。
    private func showReplacementCover(for videoURL: URL) {
        imageTaskLock.lock()
        coverImageGeneration &+= 1
        let generation = coverImageGeneration
        let oldTask = coverImageTask
        coverImageTask = nil
        imageTaskLock.unlock()
        oldTask?.cancel()

        let coverAsset = AVURLAsset(url: videoURL)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let generator = AVAssetImageGenerator(asset: coverAsset)
            generator.appliesPreferredTrackTransform = true
            if #available(macOS 15.0, *) { generator.dynamicRangePolicy = .forceSDR }
            generator.maximumSize = CGSize(width: WallpaperSnapshotPixelBudget.maximumVideoImageDimension,
                                           height: WallpaperSnapshotPixelBudget.maximumVideoImageDimension)
            guard let cgImage = try? await withTaskCancellationHandler(operation: {
                try await generator.image(at: .zero).image
            }, onCancel: { generator.cancelAllCGImageGeneration() }), !Task.isCancelled else { return }
            guard WallpaperSnapshotPixelBudget.acceptsDecodedImage(
                width: cgImage.width, height: cgImage.height, bytesPerRow: cgImage.bytesPerRow) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.imageTaskLock.lock()
                let current = self.coverImageGeneration == generation
                if current { self.coverImageTask = nil }
                self.imageTaskLock.unlock()
                guard current else { return }
                // 期间又切了一张，或者这个请求已经不是当前源 → 不要盖错图。
                let stillRequested = self.sourceFrameLock.withLock { () -> Bool in
                    guard let requested = self.sourceFrameReadiness.requestedSource else { return false }
                    return requested.url == videoURL
                }
                guard stillRequested, self.isRunning else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.replacementCoverLayer.contents = cgImage
                self.replacementCoverLayer.opacity = 1
                CATransaction.commit()
            }
        }
        imageTaskLock.lock()
        let admitted = coverImageGeneration == generation
        if admitted { coverImageTask = task }
        imageTaskLock.unlock()
        if !admitted { task.cancel() }
    }

    /// 只在主线程调用（与其它 CALayer 写入一致）。
    private func clearReplacementCover() {
        imageTaskLock.lock()
        coverImageGeneration &+= 1
        let oldTask = coverImageTask
        coverImageTask = nil
        imageTaskLock.unlock()
        oldTask?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replacementCoverLayer.opacity = 0
        replacementCoverLayer.contents = nil
        CATransaction.commit()
    }

    // MARK: - Still Frame（静帧）

    private func generateStillFrame() {
        queue.async { [weak self] in self?.generateStillFrameOnQueue() }
    }

    private func generateStillFrameOnQueue() {
        guard isRunning, let source = sourceFrameLock.withLock({ () -> VideoSourceFrameReadiness.SourceToken? in
            guard let source = sourceFrameReadiness.installedSource,
                  sourceFrameReadiness.isInstalled(source), sourceFrameReadiness.isPaused else { return nil }
            return source
        }) else { return }
        let captureTime = CMTimebaseGetTime(timebase)
        let currentAsset = AVURLAsset(url: asset.url)
        imageTaskLock.lock()
        stillImageGeneration &+= 1
        let generation = stillImageGeneration
        let oldTask = stillImageTask
        stillImageTask = nil
        imageTaskLock.unlock()
        oldTask?.cancel()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let generator = AVAssetImageGenerator(asset: currentAsset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
            if #available(macOS 15.0, *) { generator.dynamicRangePolicy = .forceSDR }
            generator.maximumSize = CGSize(width: WallpaperSnapshotPixelBudget.maximumVideoImageDimension,
                                           height: WallpaperSnapshotPixelBudget.maximumVideoImageDimension)

            // The timebase covers all loops; the asset contains only one loop.
            let duration = try? await withTaskCancellationHandler(operation: {
                try await currentAsset.load(.duration)
            }, onCancel: { currentAsset.cancelLoading() })
            let requestTime: CMTime
            if let duration, duration.isValid, duration.seconds.isFinite, duration.seconds > 0,
               captureTime.isValid, captureTime.seconds.isFinite, captureTime.seconds >= 0 {
                requestTime = CMTime(seconds: captureTime.seconds.truncatingRemainder(dividingBy: duration.seconds), preferredTimescale: 600)
            } else {
                requestTime = .zero
            }
            guard !Task.isCancelled else { return }
            guard let (cgImage, _) = try? await withTaskCancellationHandler(operation: {
                try await generator.image(at: requestTime)
            }, onCancel: { generator.cancelAllCGImageGeneration() }), !Task.isCancelled else {
                if Task.isCancelled { return }
                extLog("  [Renderer] 静帧生成失败")
                return
            }
            guard WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: cgImage.width, height: cgImage.height, bytesPerRow: cgImage.bytesPerRow) else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                self.imageTaskLock.lock()
                let current = self.stillImageGeneration == generation
                if current { self.stillImageTask = nil }
                self.imageTaskLock.unlock()
                guard current else { return }
                let shouldShow = self.sourceFrameLock.withLock { self.sourceFrameReadiness.showStill(from: source) }
                guard shouldShow else { return }
                self.stillFrameLayer.contents = cgImage
                self.stillFrameLayer.opacity = 1
            }
        }
        imageTaskLock.lock()
        let admitted = stillImageGeneration == generation
        if admitted { stillImageTask = task }
        imageTaskLock.unlock()
        if !admitted { task.cancel() }
    }
}
