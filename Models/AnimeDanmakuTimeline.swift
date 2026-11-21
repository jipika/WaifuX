import Foundation

/// Immutable media-time layout. Built only when the list, geometry or layout settings change.
/// No wall-clock state, delayed callbacks, random tracks or per-tick full-list filtering.
struct AnimeDanmakuTimeline: Sendable {
    struct Entry: Sendable {
        let danmaku: Danmaku
        let text: String
        let start: Double
        let duration: Double
        let textWidth: Double
        let y: Double

        func x(at mediaTime: Double, width: Double) -> Double {
            guard danmaku.mode == .scroll else { return width / 2 }
            let progress = (mediaTime - start) / duration
            return width + textWidth / 2 - (width + textWidth) * progress
        }
    }

    struct Style: Equatable, Sendable {
        let fontSize: Double
        let durationSeconds: Double
        let area: Double
        let lineHeight: Double
        let enableTop: Bool
        let enableBottom: Bool
        let enableScroll: Bool
        let deduplicate: Bool
        let massiveMode: Bool
        let blockedKeywords: [String]

        init(settings: DanmakuSettings) {
            fontSize = settings.fontSize.isFinite ? min(48, max(10, settings.fontSize)) : 16
            durationSeconds = settings.durationSeconds.isFinite ? min(16, max(2, settings.durationSeconds)) : 8
            area = settings.area.isFinite ? min(1, max(0.25, settings.area)) : 1
            lineHeight = settings.lineHeight.isFinite ? min(2.5, max(1, settings.lineHeight)) : 1.5
            enableTop = settings.enableTop
            enableBottom = settings.enableBottom
            enableScroll = settings.enableScroll
            deduplicate = settings.enableDeduplication
            massiveMode = settings.massiveMode
            blockedKeywords = settings.blockedKeywords.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var maximumLifetime: Double = 0

    init() {}

    init(danmakuList: [Danmaku], settings: DanmakuSettings, width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        let style = Style(settings: settings)
        let rowHeight = style.fontSize * style.lineHeight + 4
        // 「弹幕区域」限制可占用的视频高度（Kazumi danmakuArea 同款语义）。
        let usableHeight = height * style.area
        let rowCount = max(0, Int(usableHeight / rowHeight))
        guard rowCount > 0 else { return }
        var occupiedUntil = Array(repeating: -Double.infinity, count: rowCount)
        var laneCursor = 0
        var seenIDs = Set<UUID>()
        var lastTextTime: [String: Double] = [:]
        let forwardRows = Array(0..<rowCount)
        let reverseRows = Array(forwardRows.reversed())
        // Stable tie breaking also makes backward seeks choose the same lanes.
        let ordered = danmakuList.filter { $0.time.isFinite && $0.time >= 0 }.sorted {
            if $0.time == $1.time { return $0.id.uuidString < $1.id.uuidString }
            return $0.time < $1.time
        }
        for danmaku in ordered {
            guard seenIDs.insert(danmaku.id).inserted else { continue }
            switch danmaku.mode {
            case .scroll: guard style.enableScroll else { continue }
            case .top: guard style.enableTop else { continue }
            case .bottom: guard style.enableBottom else { continue }
            }
            let normalized = danmaku.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let lowerText = normalized.lowercased()
            guard !style.blockedKeywords.contains(where: { lowerText.contains($0) }) else { continue }
            if style.deduplicate, let previous = lastTextTime[normalized], danmaku.time - previous <= 5 {
                continue
            }
            lastTextTime[normalized] = danmaku.time
            // Bound both glyph work and the maximum seek lookback, even for malformed comments.
            let text = String(normalized.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            let textWidth = Self.estimatedWidth(text, fontSize: style.fontSize)
            // 滚动时长按屏幕与文本宽度缩放，保证不同长度弹幕的像素速度一致（canvas_danmaku 语义）。
            let duration = danmaku.mode == .scroll
                ? style.durationSeconds * (width + textWidth) / max(width, 1)
                : max(2, style.durationSeconds / 2)
            let rows = danmaku.mode == .bottom ? reverseRows : forwardRows
            let row: Int
            if let free = rows.first(where: { occupiedUntil[$0] <= danmaku.time }) {
                row = free
            } else if style.massiveMode {
                // 海量模式：轨道占满时轮转叠加，而不是丢弃弹幕。
                row = rows[laneCursor % rows.count]
                laneCursor += 1
            } else {
                continue
            }
            // One shared lane pool prevents fixed and scrolling modes from overlapping.
            occupiedUntil[row] = danmaku.time + duration
            entries.append(Entry(danmaku: danmaku, text: text, start: danmaku.time,
                                 duration: duration, textWidth: textWidth,
                                 y: rowHeight * (Double(row) + 0.5)))
            maximumLifetime = max(maximumLifetime, duration)
        }
    }

    /// The caller subtracts timeOffset (a positive offset delays presentation).
    /// Work is O(log n + visible-window entries), independent of episode length.
    /// lifetimeScale > 1 widens the lookback when the renderer stretches dwell time
    /// (danmaku not following playback speed).
    func visibleEntries(at mediaTime: Double, lifetimeScale: Double = 1) -> ArraySlice<Entry> {
        guard mediaTime.isFinite, !entries.isEmpty else { return entries[0..<0] }
        let scale = (lifetimeScale.isFinite && lifetimeScale > 0) ? lifetimeScale : 1
        let first = lowerBound(mediaTime - maximumLifetime * scale)
        let last = upperBound(mediaTime)
        return entries[first..<last]
    }

    private func lowerBound(_ time: Double) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = low + (high - low) / 2
            if entries[middle].start < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func upperBound(_ time: Double) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = low + (high - low) / 2
            if entries[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func estimatedWidth(_ text: String, fontSize: Double) -> Double {
        text.unicodeScalars.reduce(0) { width, scalar in
            // Conservative CJK width; layout stays deterministic without AppKit/font allocation.
            width + (scalar.value < 0x2E80 ? fontSize * 0.65 : fontSize)
        }
    }
}
