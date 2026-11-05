import Foundation

/// Evidence for one renderer's installed source and reusable video layer.
/// No pixels or clocks live here. Callers serialize every transition, and supply
/// actual AVSampleBufferDisplayLayer readiness, never a poster/decode-status proxy.
struct VideoSourceFrameReadiness: Sendable {
    struct SourceToken: Equatable, Sendable {
        let generation: UInt64
        let url: URL
    }

    struct MediaToken: Equatable, Sendable {
        let source: SourceToken
        let generation: UInt64
    }

    enum StillImage: Equatable, Sendable {
        case hidden
        case source(SourceToken)
        case unverified
    }

    private var sourceGeneration: UInt64 = 0
    private var mediaGeneration: UInt64 = 0
    private(set) var requestedSource: SourceToken?
    private(set) var installedSource: SourceToken?
    private(set) var media: MediaToken?
    private(set) var oldImageRemoved = false
    private(set) var firstFrameEnqueued = false
    private(set) var layerReady = false
    private(set) var stillImage: StillImage = .hidden
    private(set) var primeClaimed = false
    private(set) var primeInProgress = false
    private(set) var stopped = false
    var isPaused = false
    var playbackStarted = false

    /// Registers a pending request. The previous installed source remains the
    /// active media owner until install() succeeds, so a failed asynchronous
    /// load cannot strand playback in a half-replaced state.
    @discardableResult
    mutating func requestSource(_ url: URL) -> SourceToken? {
        guard !stopped else { return nil }
        sourceGeneration &+= 1
        let source = SourceToken(generation: sourceGeneration, url: url)
        requestedSource = source
        // Pending media belongs to the previous installed source; only its
        // source-specific proof remains valid. A pending new source cannot
        // borrow it, even if a same-file URL spelling differs later.
        if let installed = installedSource, installed.url == url {
            media = nil
            oldImageRemoved = false
            firstFrameEnqueued = false
            layerReady = false
            primeClaimed = false
            primeInProgress = false
        }
        return source
    }

    func isCurrentRequest(_ source: SourceToken) -> Bool {
        !stopped && requestedSource == source
    }

    func isInstalled(_ source: SourceToken) -> Bool {
        !stopped && installedSource == source
    }

    /// Installing a different source is destructive; installing the already
    /// active same-URL request only refreshes its source generation.
    @discardableResult
    mutating func install(_ source: SourceToken) -> Bool {
        guard isCurrentRequest(source) else { return false }
        let previous = installedSource
        let replacing = previous != source
        installedSource = source
        requestedSource = source
        if replacing {
            media = nil
            oldImageRemoved = false
            firstFrameEnqueued = false
            layerReady = false
            primeClaimed = false
            primeInProgress = false
            if let previous, stillImage == .source(previous) {
                // A late still from the old source must not cover the new source.
                stillImage = .unverified
            }
        }
        return true
    }

    /// Same-source recovery may keep the retained frame; only a destructive
    /// rebuild requires a displayed-image-removal callback before enqueue.
    mutating func beginMedia(requiresImageRemoval: Bool = true) -> MediaToken? {
        guard let source = installedSource, isInstalled(source) else { return nil }
        mediaGeneration &+= 1
        let token = MediaToken(source: source, generation: mediaGeneration)
        media = token
        oldImageRemoved = !requiresImageRemoval
        firstFrameEnqueued = false
        layerReady = false
        return token
    }

    func isCurrentMedia(_ token: MediaToken) -> Bool {
        isInstalled(token.source) && media == token
    }

    @discardableResult
    mutating func didRemoveOldImage(_ token: MediaToken) -> Bool {
        guard isCurrentMedia(token) else { return false }
        oldImageRemoved = true
        return true
    }

    @discardableResult
    mutating func didEnqueueDisplayableFrame(_ token: MediaToken) -> Bool {
        guard isCurrentMedia(token), oldImageRemoved else { return false }
        firstFrameEnqueued = true
        return true
    }

    @discardableResult
    mutating func observeLayerReady(_ ready: Bool, for token: MediaToken) -> Bool {
        guard isCurrentMedia(token), oldImageRemoved, firstFrameEnqueued else { return false }
        layerReady = ready
        return ready
    }

    /// A still is bookkeeping about what is actually above the video layer;
    /// a successfully extracted still NEVER supplies video readiness evidence.
    @discardableResult
    mutating func showStill(from source: SourceToken) -> Bool {
        guard isInstalled(source), isPaused else { return false }
        stillImage = .source(source)
        return true
    }

    mutating func showUnverifiedStill() { stillImage = .unverified }

    /// Only a ready video from the CURRENT media generation may remove an old
    /// still. Until the caller really hides it, a foreign still blocks success.
    @discardableResult
    mutating func revealVideo(_ token: MediaToken) -> Bool {
        guard isCurrentMedia(token), oldImageRemoved, firstFrameEnqueued, layerReady else { return false }
        stillImage = .hidden
        return true
    }

    func isReady(for url: URL) -> Bool {
        guard let token = media, token.source.url == url,
              isCurrentMedia(token), oldImageRemoved, firstFrameEnqueued, layerReady else { return false }
        switch stillImage {
        case .hidden: return true
        case .source(let source): return source == token.source
        case .unverified: return false
        }
    }

    /// One bounded prime is available per installed request, not per poll or
    /// media rebuild. A slow pending replacement must not prime the old source.
    /// Installing a paused replacement claims it immediately so a non-zero PTS
    /// first frame can become visible without changing pause intent.
    mutating func claimPrime(for url: URL) -> SourceToken? {
        guard let source = installedSource, source.url == url, isInstalled(source),
              (isPaused || !playbackStarted), !isReady(for: url), !primeClaimed else { return nil }
        primeClaimed = true
        primeInProgress = true
        return source
    }

    mutating func claimPrimeForInstalledSource() -> SourceToken? {
        guard let source = installedSource, isInstalled(source),
              (isPaused || !playbackStarted), !primeClaimed else { return nil }
        primeClaimed = true
        primeInProgress = true
        return source
    }

    var diagnostic: String {
        "source=\(installedSource.map { "\($0.generation):\($0.url.lastPathComponent)" } ?? "none") media=\(media?.generation.description ?? "none") removed=\(oldImageRemoved) enqueued=\(firstFrameEnqueued) ready=\(layerReady) still=\(stillImage) paused=\(isPaused) started=\(playbackStarted) prime=\(primeInProgress)"
    }

    mutating func finishPrimeRequest() {
        primeClaimed = false
        primeInProgress = false
    }

    mutating func finishPrime(_ source: SourceToken) {
        guard isInstalled(source) else { return }
        primeInProgress = false
    }

    /// Drop cached readiness without forgetting an image explicitly retained
    /// during deep pause. The caller separately cancels its feed generation;
    /// retained video still needs a fresh real-layer query before returning true.
    mutating func retainImageForDeepPause() {
        primeInProgress = false
        layerReady = false
    }

    /// For recovery/flush paths that do not immediately build a replacement.
    mutating func invalidateMedia() {
        media = nil
        oldImageRemoved = false
        firstFrameEnqueued = false
        layerReady = false
        primeInProgress = false
    }

    mutating func stop() {
        stopped = true
        requestedSource = nil
        installedSource = nil
        invalidateMedia()
        stillImage = .hidden
    }
}
