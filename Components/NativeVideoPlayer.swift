import AVFoundation
import Combine
import SwiftUI
import AppKit
import CoreImage
import OSLog

struct PlaybackDiagnostic: Equatable, Sendable {
    enum Category: String, Sendable {
        case accessDenied, regionDenied, formatUnsupported, network, timedOut, unknown
    }

    struct ErrorEntry: Equatable, Sendable {
        let domain: String
        let code: Int
    }

    struct Event: Equatable, Sendable {
        let domain: String
        let code: Int
        let httpStatus: Int?
        let host: String?
    }

    let category: Category
    let userMessage: String
    let httpStatusCodes: [Int]
    let mediaHost: String?
    let errorChain: [ErrorEntry]
    let events: [Event]
    let playbackID: UUID?
    let generation: UUID
    let recordedAt: Date

    var safeSummary: String {
        let errors = errorChain.map { "\($0.domain):\($0.code)" }.joined(separator: ",")
        let logEvents = events.map { "\($0.domain):\($0.code) status=\($0.httpStatus.map(String.init) ?? "none") host=\($0.host ?? "unknown")" }.joined(separator: ";")
        return "category=\(category.rawValue) host=\(mediaHost ?? "unknown") http=\(httpStatusCodes) errors=[\(errors)] events=[\(logEvents)] generation=\(generation.uuidString)"
    }

    /// Error text is used transiently for categorization, never retained or logged.
    static func make(error: Error?, events: [Event], mediaURL: URL?, playbackID: UUID?, generation: UUID, timedOut: Bool = false, eventMessages: [String] = []) -> PlaybackDiagnostic {
        var chain: [ErrorEntry] = []
        var messages = eventMessages
        var cursor = error as NSError?
        var seen: Set<ObjectIdentifier> = []
        while let current = cursor, chain.count < 8, seen.insert(ObjectIdentifier(current)).inserted {
            chain.append(ErrorEntry(domain: safeIdentifier(current.domain), code: current.code))
            messages.append(current.localizedDescription)
            if let reason = current.localizedFailureReason { messages.append(reason) }
            cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        // Some transports expose HTTP status only in NSError metadata instead of AVPlayerItemErrorLog.
        var underlyingStatus: [Int] = []
        cursor = error as NSError?
        seen.removeAll()
        while let current = cursor, seen.count < 8, seen.insert(ObjectIdentifier(current)).inserted {
            for key in ["HTTPStatusCode", "HTTPStatus", "statusCode", "NSHTTPStatusCode"] {
                if let status = current.userInfo[key] as? Int, (100...599).contains(status) { underlyingStatus.append(status) }
            }
            if let response = current.userInfo["NSURLErrorFailingURLResponseErrorKey"] as? HTTPURLResponse {
                underlyingStatus.append(response.statusCode)
            }
            cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let statusCodes = Array(Set(events.compactMap(\.httpStatus) + underlyingStatus)).sorted()
        let text = messages.joined(separator: " ").lowercased()
        let category: Category
        let message: String
        if text.contains("region") && (text.contains("denied") || text.contains("restrict") || text.contains("blocked"))
            || text.contains("区域") || text.contains("地区限制") {
            category = .regionDenied
            message = t("媒体服务拒绝了当前网络出口的区域访问，请切换播放线路，或检查当前网络与代理设置。")
        } else if statusCodes.contains(401) || statusCodes.contains(403)
            || text.contains("forbidden") || text.contains("access denied") || text.contains("permission") || text.contains("没有权限")
            || chain.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorNoPermissionsToReadFile }) {
            category = .accessDenied
            message = t("媒体服务拒绝访问，可能需要重新验证、播放地址已过期，或当前网络出口受限。请重新解析或切换线路。")
        } else if timedOut || chain.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorTimedOut }) {
            category = .timedOut
            message = t("视频连接超时，请重试或切换播放线路。")
        } else if chain.contains(where: { $0.domain == NSURLErrorDomain }) || statusCodes.contains(where: { $0 >= 500 }) {
            category = .network
            message = t("无法连接媒体服务，请检查网络后重试，或切换播放线路。")
        } else if chain.contains(where: { $0.domain == AVFoundationErrorDomain && [-11828, -11829, -11833, -11838].contains($0.code) })
            || text.contains("format") || text.contains("decode") || text.contains("格式") {
            category = .formatUnsupported
            message = t("播放地址没有返回可播放的视频，或视频格式不受支持。请重新解析或切换线路。")
        } else {
            category = .unknown
            message = t("视频播放失败，请重新解析或切换播放线路。")
        }
        return PlaybackDiagnostic(category: category, userMessage: message, httpStatusCodes: statusCodes,
                                  mediaHost: safeHost(mediaURL?.absoluteString), errorChain: chain, events: events,
                                  playbackID: playbackID, generation: generation, recordedAt: Date())
    }

    static func safeHost(_ value: String?) -> String? {
        guard let value, let host = URL(string: value)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    static func safeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !value.isEmpty, value.unicodeScalars.count <= 100,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "unknown" }
        return value
    }
}

enum VideoFrameCaptureError: LocalizedError {
    case unavailable, protectedContent, stalePlayback
    var errorDescription: String? {
        switch self {
        case .unavailable: return t("当前视频帧还未准备好，请播放后再截图。")
        case .protectedContent: return t("当前视频受内容保护，无法截取画面。")
        case .stalePlayback: return t("视频已切换，请重新截图。")
        }
    }
}

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
    /// Current load's diagnostic clears on load; the last failure survives retries for inspection.
    @Published private(set) var currentDiagnostic: PlaybackDiagnostic?
    @Published private(set) var lastDiagnostic: PlaybackDiagnostic?

    private static let logger = Logger(subsystem: "com.waifux.app", category: "AnimePlayback")

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
    private var seekID = UUID()
    private(set) var playbackID: UUID?
    private var wantsToPlay = false
    private var loadingDeadline: DispatchWorkItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var captureGenerator: AVAssetImageGenerator?
    private var captureID: UUID?
    private lazy var frameImageContext = CIContext(options: [.cacheIntermediates: false])

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
        seekID = UUID()
        let generation = loadGeneration
        loadingDeadline?.cancel()
        captureID = nil
        captureGenerator?.cancelAllCGImageGeneration()
        captureGenerator = nil
        if let videoOutput, let oldItem = avPlayer.currentItem { oldItem.remove(videoOutput) }
        videoOutput = nil
        currentDiagnostic = nil
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
        // Capture decoded media pixels, independent of AVPlayerLayer, controls and danmaku.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        videoOutput = output
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
                    self.failCurrentItem(error: item.error, item: item)
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
                guard let self, self.loadGeneration == generation, item === self.avPlayer.currentItem else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.failCurrentItem(error: error, item: item)
            }.store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.loadGeneration == generation, item === self.avPlayer.currentItem else { return }
                self.recordDiagnostic(error: item.error, item: item)
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

    func seek(to time: TimeInterval, resumeAfterSeek: Bool? = nil, completion: (@Sendable () -> Void)? = nil) {
        let resolvedResume = resumeAfterSeek ?? wantsToPlay
        let requestID = UUID()
        seekID = requestID
        avPlayer.currentItem?.cancelPendingSeeks()
        isSeeking = true
        wantsToPlay = resolvedResume
        if !resolvedResume {
            avPlayer.pause()
            loadingDeadline?.cancel()
            if state.isReady {
                state = .paused
                onStateChanged?(.paused)
            }
        }
        let generation = loadGeneration
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        avPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, self.seekID == requestID else { return }
                self.isSeeking = false
                guard finished else { completion?(); return }
                let actualTime = self.avPlayer.currentTime().seconds
                self.currentTime = actualTime.isFinite ? actualTime : time
                self.currentTimePublisher.send(self.currentTime)
                if resolvedResume && self.wantsToPlay {
                    self.avPlayer.playImmediately(atRate: Float(self.playbackRate))
                }
                completion?()
            }
        }
    }

    func skip(by interval: TimeInterval) {
        let newTime = max(0, min(totalDuration, currentTime + interval))
        seek(to: newTime, resumeAfterSeek: wantsToPlay)
    }

    /// Returns the actual media frame at the current item time, without UI/danmaku layers.
    @MainActor
    func captureCurrentFrame() async throws -> NSImage {
        try Task.checkCancellation()
        guard let item = avPlayer.currentItem, item.status == .readyToPlay else { throw VideoFrameCaptureError.unavailable }
        let generation = loadGeneration
        let requestID = UUID()
        captureGenerator?.cancelAllCGImageGeneration()
        captureGenerator = nil
        captureID = requestID
        let time = avPlayer.currentTime()
        guard time.isValid, time.seconds.isFinite else { throw VideoFrameCaptureError.unavailable }
        let hasProtectedContent: Bool
        do { hasProtectedContent = try await item.asset.load(.hasProtectedContent) }
        catch {
            try Task.checkCancellation()
            throw VideoFrameCaptureError.unavailable
        }
        guard !hasProtectedContent else { throw VideoFrameCaptureError.protectedContent }
        guard generation == loadGeneration, captureID == requestID, item === avPlayer.currentItem else { throw VideoFrameCaptureError.stalePlayback }
        if let output = videoOutput,
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            var image = CIImage(cvPixelBuffer: buffer)
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    image = image.transformed(by: try await track.load(.preferredTransform))
                }
            } catch {
                try Task.checkCancellation()
                throw VideoFrameCaptureError.unavailable
            }
            try Task.checkCancellation()
            guard generation == loadGeneration, captureID == requestID, item === avPlayer.currentItem else { throw VideoFrameCaptureError.stalePlayback }
            if let cgImage = frameImageContext.createCGImage(image, from: image.extent) {
                return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            }
        }
        // Paused items may not retain a pixel buffer. Use the same authenticated asset and
        // the captured item time, rather than taking a window screenshot or fetching a new URL.
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        captureGenerator?.cancelAllCGImageGeneration()
        captureGenerator = generator
        defer { if captureGenerator === generator { captureGenerator = nil } }
        let result: (image: CGImage, actualTime: CMTime)
        do {
            result = try await withTaskCancellationHandler {
                try await generator.image(at: time)
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.captureID == requestID else { return }
                    self.captureGenerator?.cancelAllCGImageGeneration()
                }
            }
        } catch {
            try Task.checkCancellation()
            guard generation == loadGeneration, captureID == requestID, item === avPlayer.currentItem else { throw VideoFrameCaptureError.stalePlayback }
            throw VideoFrameCaptureError.unavailable
        }
        try Task.checkCancellation()
        guard generation == loadGeneration, captureID == requestID, item === avPlayer.currentItem else { throw VideoFrameCaptureError.stalePlayback }
        return NSImage(cgImage: result.image, size: NSSize(width: CGFloat(result.image.width), height: CGFloat(result.image.height)))
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
        seekID = UUID()
        wantsToPlay = false
        loadingDeadline?.cancel()
        loadingDeadline = nil
        captureID = nil
        captureGenerator?.cancelAllCGImageGeneration()
        captureGenerator = nil
        if let videoOutput, let item = avPlayer.currentItem { item.remove(videoOutput) }
        videoOutput = nil
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
        currentDiagnostic = nil
        state = .idle
        currentTime = 0
        currentTimePublisher.send(0)
        totalDuration = 0
        bufferedDuration = 0
        isLoading = false
        isSeeking = false
    }

    // MARK: - 内部方法
    @discardableResult
    private func recordDiagnostic(error: Error?, item: AVPlayerItem?, timedOut: Bool = false) -> PlaybackDiagnostic {
        let rawEvents = Array((item?.errorLog()?.events ?? []).suffix(12))
        let events = rawEvents.map { event in
            PlaybackDiagnostic.Event(domain: PlaybackDiagnostic.safeIdentifier(event.errorDomain), code: event.errorStatusCode,
                                     httpStatus: (100...599).contains(event.errorStatusCode) ? event.errorStatusCode : nil,
                                     host: PlaybackDiagnostic.safeHost(event.uri))
        }
        let diagnostic = PlaybackDiagnostic.make(error: error, events: events, mediaURL: currentURL,
                                                 playbackID: playbackID, generation: loadGeneration, timedOut: timedOut,
                                                 eventMessages: rawEvents.compactMap(\.errorComment))
        currentDiagnostic = diagnostic
        lastDiagnostic = diagnostic
        Self.logger.error("\(diagnostic.safeSummary, privacy: .public)")
        return diagnostic
    }

    private func failCurrentItem(error: Error?, item: AVPlayerItem?, timedOut: Bool = false) {
        if case .failed = state { return }
        let diagnostic = recordDiagnostic(error: error, item: item, timedOut: timedOut)
        loadingDeadline?.cancel()
        wantsToPlay = false
        avPlayer.pause()
        state = .failed(diagnostic.userMessage)
        isLoading = false
        onStateChanged?(.failed(diagnostic.userMessage))
    }

    private func armLoadingDeadline(generation: UUID, seconds: TimeInterval) {
        guard loadingDeadline == nil || loadingDeadline?.isCancelled == true else { return }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.loadGeneration == generation, self.wantsToPlay,
                  self.state == .loading || self.state == .readyToPlay || self.state == .buffering else { return }
            self.failCurrentItem(error: URLError(.timedOut), item: self.avPlayer.currentItem, timedOut: true)
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
                    // AVPlayer stops at end of item; that is not a user pause.
                    guard !self.wantsToPlay, self.state != .finished else { return }
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
