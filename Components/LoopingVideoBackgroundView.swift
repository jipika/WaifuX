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
    let onReady: (@MainActor @Sendable () -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady)
    }

    func makeNSView(context: Context) -> LoopingVideoPlayerContainerView {
        let view = LoopingVideoPlayerContainerView(contentMode: contentMode)
        context.coordinator.attach(to: view)
        context.coordinator.update(url: url, isMuted: isMuted, in: view)
        return view
    }

    func updateNSView(_ nsView: LoopingVideoPlayerContainerView, context: Context) {
        context.coordinator.update(url: url, isMuted: isMuted, in: nsView)
    }

    static func dismantleNSView(_ nsView: LoopingVideoPlayerContainerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private weak var containerView: LoopingVideoPlayerContainerView?
        private var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var onReady: (@MainActor @Sendable () -> Void)?
        private var readyObserver: NSObjectProtocol?

        init(onReady: (@MainActor @Sendable () -> Void)?) {
            self.onReady = onReady
        }

        func attach(to view: LoopingVideoPlayerContainerView) {
            containerView = view
        }

        func update(url: URL, isMuted: Bool, in view: LoopingVideoPlayerContainerView) {
            attach(to: view)

            if currentURL != url {
                configurePlayer(with: url, in: view)
            }

            player?.isMuted = isMuted
            player?.volume = isMuted ? 0 : 1
            player?.play()
        }

        func teardown() {
            if let observer = readyObserver {
                NotificationCenter.default.removeObserver(observer)
                readyObserver = nil
            }
            looper?.disableLooping()
            looper = nil
            player?.pause()
            player = nil
            currentURL = nil
            containerView?.playerLayer.player = nil
        }

        private func configurePlayer(with url: URL, in view: LoopingVideoPlayerContainerView) {
            teardown()

            let item = AVPlayerItem(url: url)
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
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onReady?()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.onReady?()
            }

            queuePlayer.play()

            self.player = queuePlayer
            self.looper = looper
            self.currentURL = url
        }
    }
}

final class LoopingVideoPlayerContainerView: NSView {
    private let contentMode: LoopingVideoBackgroundView.ContentMode

    init(contentMode: LoopingVideoBackgroundView.ContentMode = .fill) {
        self.contentMode = contentMode
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.contentMode = .fill
        super.init(coder: coder)
    }

    /// 使用 makeBackingLayer 提供 AVPlayerLayer 作为 backing layer，
    /// 避免 macOS < 26 上 wantsLayer + 手动替换 layer 导致的几何信息丢失问题。
    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.frame = bounds
        return layer
    }

    var playerLayer: AVPlayerLayer {
        // makeBackingLayer 确保 backing layer 始终是 AVPlayerLayer
        guard let avLayer = layer as? AVPlayerLayer else {
            // 防御性兜底：理论上不会触发，但防止极端情况下的崩溃
            let fallback = AVPlayerLayer()
            fallback.videoGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
            fallback.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            fallback.frame = bounds
            self.layer = fallback
            return fallback
        }
        return avLayer
    }

    override func layout() {
        super.layout()
        // 确保 layer 尺寸与 view 同步（macOS < 26 的补充保障）
        if playerLayer.frame != bounds {
            playerLayer.frame = bounds
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // macOS < 26：加入 window 时确保 layer 尺寸正确
        // 解决 NSViewRepresentable 在 GeometryReader 中尺寸传递的时序问题
        if window != nil {
            playerLayer.frame = bounds
        }
    }
}
