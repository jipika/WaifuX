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

// MARK: - 时间模型
final class PlayerTimeModel: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var totalTime: TimeInterval = 0
    @Published var bufferedTime: TimeInterval = 0
}

// MARK: - 原生视频播放器控制器
final class NativeVideoPlayer: ObservableObject, @unchecked Sendable {
    // MARK: - Published 状态
    @Published var state: PlaybackState = .idle
    @Published var currentTime: TimeInterval = 0
    @Published var totalDuration: TimeInterval = 0
    @Published var bufferedDuration: TimeInterval = 0
    @Published var playbackRate: Double = 1.0 {
        didSet {
            avPlayer.rate = Float(playbackRate)
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
    var timemodel: PlayerTimeModel { timeModel }
    var playerLayer: NativeVideoPlayer? { self }
    
    // MARK: - 内部
    let avPlayer = AVPlayer()
    private let timeModel = PlayerTimeModel()
    private var timeObserver: Any?
    private var itemObservers: [NSKeyValueObservation] = []
    private var rateObserver: NSKeyValueObservation?
    private var boundaryObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var currentURL: URL?
    private var pendingStartTime: TimeInterval = 0
    
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
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
        }
        itemObservers.forEach { $0.invalidate() }
        rateObserver?.invalidate()
    }
    
    // MARK: - 播放器控制
    @MainActor
    func load(url: URL, startTime: TimeInterval = 0) {
        currentURL = url
        pendingStartTime = startTime
        state = .loading
        isLoading = true
        onStateChanged?(.loading)
        
        let asset = AVAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        
        // 清理旧观察者
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        
        // 观察 item 状态
        itemObservers.append(item.observe(\.status, options: [.new, .old]) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self.state = .readyToPlay
                    self.totalDuration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.timeModel.totalTime = self.totalDuration
                    self.isLoading = false
                    self.onStateChanged?(.readyToPlay)
                    self.onReady?()
                    // 如果有待恢复的播放进度，先 seek 再播放
                    if self.pendingStartTime > 0 {
                        let targetTime = self.pendingStartTime
                        self.pendingStartTime = 0
                        // 先开始播放让 AVPlayerLayer 初始化渲染，再 seek 避免画面不更新
                        self.avPlayer.play()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            self?.avPlayer.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    } else {
                        self.avPlayer.play()
                    }
                case .failed:
                    let errorMsg = item.error?.localizedDescription ?? "未知错误"
                    self.state = .failed(errorMsg)
                    self.isLoading = false
                    self.onStateChanged?(.failed(errorMsg))
                    self.onFinish?(item.error)
                default:
                    break
                }
            }
        })
        
        // 观察缓冲状态
        itemObservers.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if item.isPlaybackLikelyToKeepUp && self.state == .buffering {
                    // 根据当前播放速率决定恢复到 playing 还是 paused
                    if self.avPlayer.rate > 0 {
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
                if item.isPlaybackBufferEmpty && (self.state == .playing || self.state == .paused || self.state == .readyToPlay) {
                    self.state = .buffering
                    self.onStateChanged?(.buffering)
                }
            }
        })
        
        // 观察 loadedTimeRanges
        itemObservers.append(item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if let range = item.loadedTimeRanges.first?.timeRangeValue {
                let buffered = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
                DispatchQueue.main.async {
                    self.bufferedDuration = buffered
                    self.timeModel.bufferedTime = buffered
                }
            }
        })
        
        avPlayer.replaceCurrentItem(with: item)
        
        // 设置播放速率
        avPlayer.rate = Float(playbackRate)
        avPlayer.volume = Float(playbackVolume)
        avPlayer.isMuted = isMuted
        
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
                self.state = .finished
                self.onStateChanged?(.finished)
                self.onFinish?(nil)
            }
            .store(in: &cancellables)
    }
    
    func play() {
        guard state == .readyToPlay || state == .paused || state == .buffering || state == .finished else { return }
        avPlayer.play()
        avPlayer.rate = Float(playbackRate)
        state = .playing
        onStateChanged?(.playing)
    }
    
    func pause() {
        avPlayer.pause()
        if state == .playing || state == .buffering {
            state = .paused
            onStateChanged?(.paused)
        }
    }
    
    func seek(to time: TimeInterval, resumeAfterSeek: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        isSeeking = true
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self else {
                completion?()
                return
            }
            let actualTime = self.avPlayer.currentTime().seconds.isFinite ? self.avPlayer.currentTime().seconds : time
            self.currentTime = actualTime
            self.timeModel.currentTime = actualTime
            self.isSeeking = false
            if resumeAfterSeek && self.state != .playing {
                self.avPlayer.play()
                self.avPlayer.rate = Float(self.playbackRate)
                self.state = .playing
                self.onStateChanged?(.playing)
            }
            completion?()
        }
    }
    
    func skip(by interval: TimeInterval) {
        let newTime = max(0, min(totalDuration, currentTime + interval))
        seek(to: newTime)
    }
    
    func stop() {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        state = .idle
        currentTime = 0
        totalDuration = 0
        bufferedDuration = 0
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        cancellables.removeAll()
        onStateChanged?(.idle)
    }
    
    // MARK: - 内部方法
    private func setupPlayerObservers() {
        // 观察 rate 变化
        rateObserver = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if player.rate > 0 && (self.state == .readyToPlay || self.state == .paused || self.state == .buffering) {
                    self.state = .playing
                    self.onStateChanged?(.playing)
                } else if player.rate == 0 && self.state == .playing {
                    self.state = .paused
                    self.onStateChanged?(.paused)
                }
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
            self.timeModel.currentTime = seconds
            
            // 报告缓冲变化
            if let item = self.avPlayer.currentItem,
               let range = item.loadedTimeRanges.first?.timeRangeValue {
                let buffered = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
                self.bufferedDuration = buffered
                self.timeModel.bufferedTime = buffered
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
}
