import AVFoundation
import Combine
import SwiftUI

// MARK: - 播放状态
enum PlaybackState: Equatable {
    case idle
    case loading
    case readyToPlay
    case playing
    case paused
    case buffering
    case finished
    case failed(String)

    var isPlaying: Bool {
        self == .playing || self == .buffering
    }

    var isReady: Bool {
        self == .readyToPlay || self == .playing || self == .paused || self == .buffering || self == .finished
    }
}

// MARK: - 原生视频播放器控制器
final class NativeVideoPlayer: ObservableObject, @unchecked Sendable {
    // MARK: - Published 状态（低频变化，触发 objectWillChange 安全）
    @Published var state: PlaybackState = .idle
    @Published var totalDuration: TimeInterval = 0
    @Published var bufferedDuration: TimeInterval = 0

    // MARK: - 高频数据（隔离：不走 @Published，避免 objectWillChange 污染所有观察者）
    /// 当前播放时间 —— 每 0.5s 更新一次，仅通过 currentTimePublisher 推送给需要的视图
    private(set) var currentTime: TimeInterval = 0
    /// 时间更新 Publisher（Combine），供视图 .onReceive 精确订阅
    let currentTimePublisher = PassthroughSubject<TimeInterval, Never>()
    @Published var playbackRate: Double = 1.0 {
        didSet {
            if wantsToPlay { avPlayer.rate = Float(playbackRate) }
        }
    }
    @Published var playbackVolume: Double = 1.0 {
        didSet {
            avPlayer.volume = Float(playbackVolume)
        }
    }
    @Published var isMuted: Bool = false {
        didSet {
            avPlayer.isMuted = isMuted
        }
    }
    @Published var isLoading: Bool = false
    @Published var isSeeking: Bool = false

    // 保持与 KSPlayer Coordinator 兼容的属性名
    var playerLayer: NativeVideoPlayer? { self }

    // MARK: - 内部
    let avPlayer = AVPlayer()
    private var timeObserver: Any?
    private var itemObservers: [NSKeyValueObservation] = []
    private var rateObserver: NSKeyValueObservation?
    private var boundaryObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var currentURL: URL?
    private var pendingStartTime: TimeInterval = 0
    private var loadGeneration = UUID()
    private(set) var playbackID: UUID?
    private var wantsToPlay = false
    private var loadingDeadline: DispatchWorkItem?

    // MARK: - 回调（兼容 KSPlayer 风格）
    var onStateChanged: ((PlaybackState) -> Void)?
    var onBufferChanged: ((Int, TimeInterval) -> Void)?
    var onFinish: ((Error?) -> Void)?
    var onReady: (() -> Void)?

    // MARK: - 初始化
    init() {
        setupPlayerObservers()
    }

    deinit {
        tearDownPlayerResources(invalidateRateObserver: true)
    }

    // MARK: - 播放器控制
    @MainActor
    func load(url: URL, startTime: TimeInterval = 0, httpHeaders: [String: String] = [:], playbackID: UUID? = nil) {
        self.playbackID = playbackID
        loadGeneration = UUID()
        let generation = loadGeneration
        loadingDeadline?.cancel()
        avPlayer.currentItem?.cancelPendingSeeks()
        cancellables.removeAll()
        currentTime = 0
        totalDuration = 0
        bufferedDuration = 0
        isSeeking = false
        wantsToPlay = true
        currentURL = url
        pendingStartTime = startTime
        state = .loading
        isLoading = true
        onStateChanged?(.loading)

        let asset = AVURLAsset(url: url, options: httpHeaders.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
        let item = AVPlayerItem(asset: asset)
        // 优化高码率/B帧视频的缓冲性能
        item.preferredForwardBufferDuration = 3.0
        item.seekingWaitsForVideoCompositionRendering = false

        // 清理旧观察者
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()

        // 观察 item 状态
        itemObservers.append(item.observe(\.status, options: [.new, .old]) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.loadGeneration == generation, item === self.avPlayer.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    self.state = .readyToPlay
                    self.totalDuration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.isLoading = false
                    self.onStateChanged?(.readyToPlay)
                    self.onReady?()
                    // 如果有待恢复的播放进度，先 seek 再播放
                    if self.pendingStartTime > 0 {
                        let targetTime = self.pendingStartTime
                        self.pendingStartTime = 0
                        // seek completion 绑定本次加载代次，换集后不再影响新视频。
                        self.seek(to: targetTime, resumeAfterSeek: self.wantsToPlay)
                    } else if self.wantsToPlay {
                        self.avPlayer.playImmediately(atRate: Float(self.playbackRate))
                    }
                    if self.wantsToPlay, self.avPlayer.timeControlStatus != .playing {
                        self.state = .buffering
                        self.onStateChanged?(.buffering)
                    }
                case .failed:
                    let errorMsg = item.error?.localizedDescription ?? t("common.unknownError")
                    self.failCurrentItem(errorMsg)
                default:
                    break
                }
            }
        })

        // 观察缓冲状态
        itemObservers.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.loadGeneration == generation, item === self.avPlayer.currentItem else { return }
                if item.isPlaybackLikelyToKeepUp && self.state == .buffering {
                    // 根据当前播放速率决定恢复到 playing 还是 paused
                    if self.wantsToPlay {
                        self.avPlayer.playImmediately(atRate: Float(self.playbackRate))
                        self.loadingDeadline?.cancel()
                        self.state = .playing
                        self.onStateChanged?(.playing)
                    } else {
                        self.state = .paused
                        self.onStateChanged?(.paused)
                    }
                }
            }
        })

        itemObservers.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.loadGeneration == generation, item === self.avPlayer.currentItem else { return }
                if item.isPlaybackBufferEmpty && self.wantsToPlay && self.state.isReady {
                    self.state = .buffering
                    self.onStateChanged?(.buffering)
                    self.armLoadingDeadline(generation: generation, seconds: 25)
                }
            }
        })

        // 观察 loadedTimeRanges
        itemObservers.append(item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
                if let range = item.loadedTimeRanges.first?.timeRangeValue {
                    let buffered = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
                    DispatchQueue.main.async {
                        guard self.loadGeneration == generation, item === self.avPlayer.currentItem else { return }
                        self.bufferedDuration = buffered
                    }
                }
        })

        avPlayer.replaceCurrentItem(with: item)

        // 设置播放速率
        avPlayer.rate = Float(playbackRate)
        avPlayer.volume = Float(playbackVolume)
        avPlayer.isMuted = isMuted
        armLoadingDeadline(generation: generation, seconds: 30)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.loadGeneration == generation else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.failCurrentItem(error?.localizedDescription ?? t("common.unknownError"))
            }.store(in: &cancellables)

        // 设置时间观察
        setupTimeObserver()

        // 监听播放完成
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .compactMap { $0.object as? AVPlayerItem }
            .filter { [weak self] item in
                item == self?.avPlayer.currentItem
            }
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.loadGeneration == generation else { return }
                self.loadingDeadline?.cancel()
                self.wantsToPlay = false
                self.state = .finished
                self.onStateChanged?(.finished)
                self.onFinish?(nil)
            }
            .store(in: &cancellables)
    }

    func play() {
        guard state == .readyToPlay || state == .paused || state == .buffering || state == .finished else { return }
        wantsToPlay = true
        avPlayer.playImmediately(atRate: Float(playbackRate))
        state = .playing
        onStateChanged?(.playing)
    }

    func pause() {
        wantsToPlay = false
        loadingDeadline?.cancel()
        avPlayer.pause()
        if state == .playing || state == .buffering {
            state = .paused
            onStateChanged?(.paused)
        }
    }

    func seek(to time: TimeInterval, resumeAfterSeek: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        isSeeking = true
        if resumeAfterSeek { wantsToPlay = true }
        let generation = loadGeneration
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                self.isSeeking = false
                guard finished else { completion?(); return }
                let actualTime = self.avPlayer.currentTime().seconds
                self.currentTime = actualTime.isFinite ? actualTime : time
                self.currentTimePublisher.send(self.currentTime)
                if resumeAfterSeek && self.wantsToPlay {
                    self.avPlayer.playImmediately(atRate: Float(self.playbackRate))
                }
                completion?()
            }
        }
    }

    func skip(by interval: TimeInterval) {
        let newTime = max(0, min(totalDuration, currentTime + interval))
        seek(to: newTime)
    }

    func stop() {
        tearDownPlayerResources(invalidateRateObserver: false)
        resetPlaybackState()
        onStateChanged?(.idle)
    }

    func releaseResources() {
        tearDownPlayerResources(invalidateRateObserver: true)
        resetPlaybackState()
        onStateChanged = nil
        onBufferChanged = nil
        onFinish = nil
        onReady = nil
    }

    private func tearDownPlayerResources(invalidateRateObserver: Bool) {
        loadGeneration = UUID()
        wantsToPlay = false
        loadingDeadline?.cancel()
        loadingDeadline = nil
        avPlayer.currentItem?.cancelPendingSeeks()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = boundaryObserver {
            avPlayer.removeTimeObserver(observer)
            boundaryObserver = nil
        }
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        if invalidateRateObserver {
            rateObserver?.invalidate()
            rateObserver = nil
        }
        cancellables.removeAll()
        currentURL = nil
        pendingStartTime = 0
    }

    private func resetPlaybackState() {
        state = .idle
        currentTime = 0
        currentTimePublisher.send(0)
        totalDuration = 0
        bufferedDuration = 0
        isLoading = false
        isSeeking = false
    }

    // MARK: - 内部方法
    private func failCurrentItem(_ message: String) {
        if case .failed = state { return }
        loadingDeadline?.cancel()
        wantsToPlay = false
        avPlayer.pause()
        state = .failed(message)
        isLoading = false
        onStateChanged?(.failed(message))
    }

    private func armLoadingDeadline(generation: UUID, seconds: TimeInterval) {
        guard loadingDeadline == nil || loadingDeadline?.isCancelled == true else { return }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.loadGeneration == generation, self.wantsToPlay,
                  self.state == .loading || self.state == .readyToPlay || self.state == .buffering else { return }
            self.failCurrentItem("视频连接超时，请重试")
        }
        loadingDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: deadline)
    }

    private func setupPlayerObservers() {
        // rate=0 也可能是网络缓冲；使用真实 timeControlStatus 保留用户播放意图。
        rateObserver = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            let item = player.currentItem
            DispatchQueue.main.async {
                guard item === self.avPlayer.currentItem, item != nil, self.state.isReady else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.loadingDeadline?.cancel()
                    self.state = .playing
                case .waitingToPlayAtSpecifiedRate:
                    guard self.wantsToPlay else { return }
                    self.state = .buffering
                    self.armLoadingDeadline(generation: self.loadGeneration, seconds: 25)
                case .paused:
                    guard !self.wantsToPlay else { return }
                    self.state = .paused
                @unknown default: return
                }
                self.onStateChanged?(self.state)
            }
        }
    }

    private func setupTimeObserver() {
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            self.currentTime = seconds
            self.currentTimePublisher.send(seconds)

            // 报告缓冲变化
            if let item = self.avPlayer.currentItem,
               let range = item.loadedTimeRanges.first?.timeRangeValue {
                let buffered = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
                self.bufferedDuration = buffered
            }
        }
    }
}

// MARK: - SwiftUI 视图
struct NativeVideoPlayerView: NSViewRepresentable {
    @ObservedObject var player: NativeVideoPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true // 防止视频内容渲染超出容器边界

        let playerLayer = AVPlayerLayer(player: player.avPlayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(playerLayer)

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 确保 AVPlayerLayer 始终与 NSView bounds 同步，防止动画/快速切换时 frame 异常
        if let playerLayer = nsView.layer?.sublayers?.first as? AVPlayerLayer {
            playerLayer.frame = nsView.bounds
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.layer?.sublayers?.forEach { layer in
            if let playerLayer = layer as? AVPlayerLayer {
                playerLayer.player = nil
            }
            layer.removeFromSuperlayer()
        }
    }
}
