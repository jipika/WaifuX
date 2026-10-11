import SwiftUI
import AVKit
import AVFoundation
import AppKit

struct LoopingVideoBackgroundView: NSViewRepresentable {
    enum ContentMode {
        case fill
        case fit
    }

    let url: URL
    let isMuted: Bool
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0
    /// 主源播放失败时的回退源（例如动态桌面：轻量预览片缺失 → 原片）。仅回退一次。
    var fallbackURL: URL?
    let onReady: (@MainActor @Sendable () -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady)
    }

    func makeNSView(context: Context) -> LoopingVideoPlayerContainerView {
        let view = LoopingVideoPlayerContainerView(
            contentMode: contentMode,
            cornerRadius: cornerRadius
        )
        context.coordinator.attach(to: view)
        context.coordinator.update(url: url, isMuted: isMuted, fallbackURL: fallbackURL, in: view)
        return view
    }

    func updateNSView(_ nsView: LoopingVideoPlayerContainerView, context: Context) {
        nsView.setCornerRadius(cornerRadius)
        context.coordinator.update(url: url, isMuted: isMuted, fallbackURL: fallbackURL, in: nsView)
    }

    static func dismantleNSView(_ nsView: LoopingVideoPlayerContainerView, coordinator: Coordinator) {
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
        private var readyObserver: NSObjectProtocol?
        private var failedObserver: NSObjectProtocol?
        private var statusObservation: NSKeyValueObservation?
        private var resolveTask: Task<Void, Never>?
        private var didSignalReady = false
        /// 主源失败后的回退源与「只回退一次」标记
        private var fallbackURL: URL?
        private var didTryFallback = false

        init(onReady: (@MainActor @Sendable () -> Void)?) {
            self.onReady = onReady
        }

        func attach(to view: LoopingVideoPlayerContainerView) {
            containerView = view
        }

        func update(url: URL, isMuted: Bool, fallbackURL: URL?, in view: LoopingVideoPlayerContainerView) {
            attach(to: view)
            self.fallbackURL = fallbackURL

            if requestedURL != url {
                configurePlayer(with: url, in: view)
            }

            player?.isMuted = isMuted
            player?.volume = isMuted ? 0 : 1
            player?.play()
        }

        func teardown() {
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
            guard !didSignalReady else { return }
            didSignalReady = true
            onReady?()
        }

        private func configurePlayer(with url: URL, in view: LoopingVideoPlayerContainerView) {
            teardown()
            requestedURL = url
            didSignalReady = false

            // 本地文件：直接播
            if url.isFileURL {
                startPlayback(with: url, in: view)
                return
            }

            // Wallsflow 等：CDN 假 Range，必须先整文件落地再播，否则 -11850 黑屏
            if WallsflowService.isProtectedMediaURL(url) {
                resolveTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let playable = try await VideoPreloader.shared.resolvePlayableURL(for: url)
                        guard !Task.isCancelled, self.requestedURL == url else { return }
                        guard let container = self.containerView else { return }
                        self.startPlayback(with: playable, in: container)
                    } catch {
                        print("[LoopingVideoBackground] resolve/download failed: \(url.lastPathComponent) \(error)")
                        self.signalReadyOnce()
                    }
                }
                // 下载期间先结束 loading 遮罩，由底层封面顶着
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.signalReadyOnce()
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
            queuePlayer.actionAtItemEnd = .none
            queuePlayer.automaticallyWaitsToMinimizeStalling = true

            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            view.playerLayer.player = queuePlayer

            readyObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.signalReadyOnce() }
            }

            failedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.signalReadyOnce() }
            }

            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                let status = observed.status
                let errorDescription = observed.error?.localizedDescription ?? "?"
                DispatchQueue.main.async {
                    guard let self else { return }
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
                self?.signalReadyOnce()
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
