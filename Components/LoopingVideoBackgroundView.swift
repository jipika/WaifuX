import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// A retained hosting tree can be hidden without a SwiftUI dismantle pass.
/// Owners use this signal to tear down decoding synchronously when dismissing.
@MainActor
final class LoopingVideoPlaybackActivity {
    private var handlers: [UUID: () -> Void] = [:]
    private(set) var isActive = false

    func resume() { isActive = true }
    func suspend() {
        isActive = false
        for handler in Array(handlers.values) { handler() }
    }
    func observeSuspension(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }
    func removeObserver(_ token: UUID) { handlers.removeValue(forKey: token) }
}

struct LoopingVideoBackgroundView: NSViewRepresentable {
    enum ContentMode {
        case fill
        case fit
    }

    let url: URL
    let isMuted: Bool
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0
    var isActive: Bool = true
    var activity: LoopingVideoPlaybackActivity?
    /// 主源播放失败时的回退源（例如动态桌面：轻量预览片缺失 → 原片）。仅回退一次。
    var fallbackURL: URL?
    /// Unlike onReady (which also settles errors/timeouts), this proves a displayable frame.
    var onFirstFrame: (@MainActor @Sendable () -> Void)? = nil
    let onReady: (@MainActor @Sendable () -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onFirstFrame: onFirstFrame)
    }

    func makeNSView(context: Context) -> LoopingVideoPlayerContainerView {
        let view = LoopingVideoPlayerContainerView(
            contentMode: contentMode,
            cornerRadius: cornerRadius
        )
        context.coordinator.attach(to: view)
        context.coordinator.bind(activity)
        context.coordinator.update(url: url, isMuted: isMuted, isActive: isActive, fallbackURL: fallbackURL, in: view)
        return view
    }

    func updateNSView(_ nsView: LoopingVideoPlayerContainerView, context: Context) {
        nsView.setCornerRadius(cornerRadius)
        context.coordinator.setCallbacks(onReady: onReady, onFirstFrame: onFirstFrame)
        context.coordinator.bind(activity)
        context.coordinator.update(url: url, isMuted: isMuted, isActive: isActive, fallbackURL: fallbackURL, in: nsView)
    }

    static func dismantleNSView(_ nsView: LoopingVideoPlayerContainerView, coordinator: Coordinator) {
        coordinator.unbindActivity()
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private weak var containerView: LoopingVideoPlayerContainerView?
        private var requestedURL: URL?
        private var playingURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var onReady: (@MainActor @Sendable () -> Void)?
        private var onFirstFrame: (@MainActor @Sendable () -> Void)?
        private var firstFrameObservation: NSKeyValueObservation?
        private var didSignalFirstFrame = false
        private var requestedMuted = true
        private var readyObserver: NSObjectProtocol?
        private var failedObserver: NSObjectProtocol?
        private var statusObservation: NSKeyValueObservation?
        private var resolveTask: Task<Void, Never>?
        private var didSignalReady = false
        /// 主源失败后的回退源与「只回退一次」标记
        private var fallbackURL: URL?
        private var didTryFallback = false
        private var generation: UInt64 = 0
        private weak var activity: LoopingVideoPlaybackActivity?
        private var activityToken: UUID?

        func bind(_ activity: LoopingVideoPlaybackActivity?) {
            guard self.activity !== activity else { return }
            unbindActivity()
            self.activity = activity
            activityToken = activity?.observeSuspension { [weak self] in self?.teardown() }
        }

        func unbindActivity() {
            if let activityToken { activity?.removeObserver(activityToken) }
            activityToken = nil
            activity = nil
        }

        init(onReady: (@MainActor @Sendable () -> Void)?,
             onFirstFrame: (@MainActor @Sendable () -> Void)? = nil) {
            self.onReady = onReady
            self.onFirstFrame = onFirstFrame
        }

        func setCallbacks(onReady: (@MainActor @Sendable () -> Void)?,
                          onFirstFrame: (@MainActor @Sendable () -> Void)?) {
            self.onReady = onReady
            self.onFirstFrame = onFirstFrame
        }

        func attach(to view: LoopingVideoPlayerContainerView) {
            containerView = view
        }

        func update(url: URL, isMuted: Bool, isActive: Bool, fallbackURL: URL?, in view: LoopingVideoPlayerContainerView) {
            attach(to: view)
            guard isActive, activity?.isActive != false else { teardown(); return }
            self.fallbackURL = fallbackURL
            requestedMuted = isMuted

            if requestedURL != url {
                configurePlayer(with: url, in: view)
            }

            player?.isMuted = isMuted
            player?.volume = isMuted ? 0 : 1
            player?.play()
        }

        func teardown() {
            generation &+= 1
            firstFrameObservation?.invalidate()
            firstFrameObservation = nil
            didSignalFirstFrame = false
            resolveTask?.cancel()
            resolveTask = nil
            if let observer = readyObserver {
                NotificationCenter.default.removeObserver(observer)
                readyObserver = nil
            }
            if let observer = failedObserver {
                NotificationCenter.default.removeObserver(observer)
                failedObserver = nil
            }
            statusObservation?.invalidate()
            statusObservation = nil
            looper?.disableLooping()
            looper = nil
            player?.pause()
            player = nil
            requestedURL = nil
            playingURL = nil
            didSignalReady = false
            didTryFallback = false
            containerView?.playerLayer.player = nil
        }

        private func signalReadyOnce() {
            guard requestedURL != nil, !didSignalReady else { return }
            didSignalReady = true
            onReady?()
        }

        private func configurePlayer(with url: URL, in view: LoopingVideoPlayerContainerView) {
            teardown()
            requestedURL = url
            let requestGeneration = generation
            didSignalReady = false

            // 本地文件：可播性兜底——AVFoundation 打不开（如 elst 计数损坏的
            // Workshop 视频）先用内置 ffmpeg 转封装修复（与桌面应用链路共享缓存），
            // 否则背景层直接黑屏、连封面都不垫。
            if url.isFileURL {
                resolveTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let playable = try await VideoRepairService.playableVideoURL(for: url)
                        guard !Task.isCancelled, self.generation == requestGeneration, self.requestedURL == url else { return }
                        guard let container = self.containerView else { return }
                        self.startPlayback(with: playable, in: container)
                    } catch is CancellationError {
                        // teardown 已清场
                    } catch {
                        guard self.generation == requestGeneration, !Task.isCancelled else { return }
                        print("[LoopingVideoBackground] repair failed: \(url.lastPathComponent) \(error)")
                        self.signalReadyOnce()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.generation == requestGeneration else { return }
                    self.signalReadyOnce()
                }
                return
            }

            // Wallsflow 等：CDN 假 Range，必须先整文件落地再播，否则 -11850 黑屏
            if WallsflowService.isProtectedMediaURL(url) {
                resolveTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let playable = try await VideoPreloader.shared.resolvePlayableURL(for: url)
                        guard !Task.isCancelled, self.generation == requestGeneration, self.requestedURL == url else { return }
                        guard let container = self.containerView else { return }
                        self.startPlayback(with: playable, in: container)
                    } catch {
                        guard self.generation == requestGeneration, !Task.isCancelled else { return }
                        print("[LoopingVideoBackground] resolve/download failed: \(url.lastPathComponent) \(error)")
                        self.signalReadyOnce()
                    }
                }
                // 下载期间先结束 loading 遮罩，由底层封面顶着
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.generation == requestGeneration else { return }
                    self.signalReadyOnce()
                }
                return
            }

            // 其他远程：带可选自定义头直接播
            startPlayback(with: url, in: view, remoteHeaders: nil)
        }

        private func startPlayback(
            with url: URL,
            in view: LoopingVideoPlayerContainerView,
            remoteHeaders: [String: String]? = nil
        ) {
            guard requestedURL != nil else { return }
            generation &+= 1
            let playbackGeneration = generation
            firstFrameObservation?.invalidate()
            firstFrameObservation = nil
            didSignalFirstFrame = false
            // 清理上一次播放器，但保留 requestedURL / resolveTask 语义
            if let observer = readyObserver {
                NotificationCenter.default.removeObserver(observer)
                readyObserver = nil
            }
            if let observer = failedObserver {
                NotificationCenter.default.removeObserver(observer)
                failedObserver = nil
            }
            statusObservation?.invalidate()
            statusObservation = nil
            looper?.disableLooping()
            looper = nil
            player?.pause()
            player = nil

            let item: AVPlayerItem = {
                if url.isFileURL {
                    return AVPlayerItem(url: url)
                }
                var options: [String: Any] = [
                    AVURLAssetPreferPreciseDurationAndTimingKey: false
                ]
                let headers = remoteHeaders ?? WallsflowService.mediaRequestHeaders(for: url)
                if let headers {
                    options["AVURLAssetHTTPHeaderFieldsKey"] = headers
                }
                return AVPlayerItem(asset: AVURLAsset(url: url, options: options))
            }()

            if #available(macOS 10.15, *) {
                item.seekingWaitsForVideoCompositionRendering = true
            }
            item.audioTimePitchAlgorithm = .timeDomain

            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = requestedMuted
            queuePlayer.volume = requestedMuted ? 0 : 1
            queuePlayer.actionAtItemEnd = .none
            queuePlayer.automaticallyWaitsToMinimizeStalling = true

            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            view.playerLayer.player = queuePlayer
            firstFrameObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { [weak self] in
                    guard ready, let self, self.generation == playbackGeneration,
                          self.containerView?.playerLayer.isReadyForDisplay == true,
                          self.containerView?.playerLayer.player === self.player,
                          !self.didSignalFirstFrame else { return }
                    self.didSignalFirstFrame = true
                    self.onFirstFrame?()
                }
            }

            readyObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == playbackGeneration else { return }
                    self.signalReadyOnce()
                }
            }

            failedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == playbackGeneration else { return }
                    self.signalReadyOnce()
                }
            }

            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                let status = observed.status
                let errorDescription = observed.error?.localizedDescription ?? "?"
                DispatchQueue.main.async {
                    guard let self, self.generation == playbackGeneration else { return }
                    guard status == .readyToPlay || status == .failed else { return }
                    if status == .failed {
                        print("[LoopingVideoBackground] item failed: \(errorDescription)")
                        // 主源不可用（例如轻量预览片缺失）→ 回退备用源，只重试一次
                        if !self.didTryFallback, let fallback = self.fallbackURL, let container = self.containerView {
                            self.didTryFallback = true
                            print("[LoopingVideoBackground] fallback → \(fallback.lastPathComponent)")
                            self.startPlayback(with: fallback, in: container)
                            return
                        }
                    }
                    self.signalReadyOnce()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.generation == playbackGeneration else { return }
                self.signalReadyOnce()
            }

            queuePlayer.play()

            self.player = queuePlayer
            self.looper = looper
            self.playingURL = url
        }
    }
}

final class LoopingVideoPlayerContainerView: NSView {
    private let contentMode: LoopingVideoBackgroundView.ContentMode
    private var cornerRadius: CGFloat

    init(
        contentMode: LoopingVideoBackgroundView.ContentMode = .fill,
        cornerRadius: CGFloat = 0
    ) {
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.contentMode = .fill
        self.cornerRadius = 0
        super.init(coder: coder)
    }

    /// 使用 makeBackingLayer 提供 AVPlayerLayer 作为 backing layer，
    /// 避免 macOS < 26 上 wantsLayer + 手动替换 layer 导致的几何信息丢失问题。
    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.frame = bounds
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = cornerRadius > 0
        return layer
    }

    var playerLayer: AVPlayerLayer {
        guard let avLayer = layer as? AVPlayerLayer else {
            let fallback = AVPlayerLayer()
            fallback.videoGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
            fallback.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            fallback.frame = bounds
            fallback.cornerRadius = cornerRadius
            fallback.masksToBounds = cornerRadius > 0
            self.layer = fallback
            return fallback
        }
        return avLayer
    }

    func setCornerRadius(_ cornerRadius: CGFloat) {
        guard self.cornerRadius != cornerRadius else { return }
        self.cornerRadius = cornerRadius
        playerLayer.cornerRadius = cornerRadius
        playerLayer.masksToBounds = cornerRadius > 0
    }

    override func layout() {
        super.layout()
        if playerLayer.frame != bounds {
            playerLayer.frame = bounds
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            playerLayer.frame = bounds
        }
    }
}
