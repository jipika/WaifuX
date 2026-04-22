import SwiftUI
import AVKit
import AVFoundation
import AppKit

struct LoopingVideoBackgroundView: NSViewRepresentable {
    let url: URL
    let isMuted: Bool
    let onReady: (@MainActor @Sendable () -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady)
    }

    func makeNSView(context: Context) -> LoopingVideoPlayerContainerView {
        let view = LoopingVideoPlayerContainerView()
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
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            let newLayer = AVPlayerLayer()
            newLayer.videoGravity = .resizeAspectFill
            self.layer = newLayer
            return newLayer
        }
        return layer
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
