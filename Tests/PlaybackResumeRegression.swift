import Foundation

/// 独立回归：tmp/playback-resume-test.sh（从生产管理器提取纯策略后编译）。
/// 不把整个 12k 行管理器复制进测试，也不另写一份实现。
@main
struct PlaybackResumeRegression {
    private static var checks = 0

    static func main() throws {
        try expect(VideoPlaybackResumePolicy.validPosition(nil) == nil, "missing time is ignored")
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0, 0.5, 1] {
            try expect(VideoPlaybackResumePolicy.validPosition(invalid) == nil,
                       "invalid time cannot overwrite last valid position: \(invalid)")
        }
        try expect(VideoPlaybackResumePolicy.validPosition(31.25) == 31.25,
                   "valid playback position is retained")

        try expect(VideoPlaybackResumePolicy.isNearEnd(59.2, duration: 60), "loop tail starts at zero")
        try expect(!VideoPlaybackResumePolicy.isNearEnd(30, duration: 60), "mid-loop resumes")
        try expect(!VideoPlaybackResumePolicy.isNearEnd(30, duration: .nan), "indefinite duration is not a tail")
        try expect(VideoPlaybackResumePolicy.clampedPosition(59.2, duration: 60) == 0,
                   "near-end clamp produces zero rather than an end-frame seek")
        try expect(VideoPlaybackResumePolicy.clampedPosition(30, duration: 60) == 30,
                   "finite in-range position is unchanged")
        try expect(VideoPlaybackResumePolicy.clampedPosition(70, duration: 60) == 0,
                   "stale position beyond duration restarts")
        try expect(VideoPlaybackResumePolicy.clampedPosition(30, duration: .infinity) == 30,
                   "infinite duration cannot poison seek")

        try expect(VideoPlaybackResumePolicy.isPlaybackActive(onEndModeScreens: [], screenIDs: ["1"]),
                   "looping video resumes")
        try expect(!VideoPlaybackResumePolicy.isPlaybackActive(onEndModeScreens: ["1"], screenIDs: ["1"]),
                   "on-end video never resumes into scheduler ownership")
        try expect(!VideoPlaybackResumePolicy.isPlaybackActive(onEndModeScreens: [], screenIDs: []),
                   "empty owners cannot drive a shared pipeline")
        try expect(VideoPlaybackResumePolicy.isPlaybackActive(
            onEndModeScreens: ["1"], screenIDs: ["1", "2"]
        ) == false, "mixed on-end/shared owner is left to scheduler")

        let paths = (0..<65).map { "/videos/\($0).mp4" }
        let positions = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($1, Double($0 + 2)) })
        let pruned = VideoPlaybackResumePolicy.pruning(positions, activePaths: [paths[64]])
        try expect(pruned.count == 1 && pruned[paths[64]] == 66,
                   "bounded history favors the current source")
        try expect(VideoPlaybackResumePolicy.pruning(["/a": 12], activePaths: []) == ["/a": 12],
                   "history is not cleared when under limit")

        let manager = try String(
            contentsOf: repoRoot.appendingPathComponent("Services/VideoWallpaperManager.swift"),
            encoding: .utf8
        )
        let restore = try section(in: manager, from: "private func applySavedPlaybackPositions()", until: "private func finishSavedPlaybackPositionRestore")
        let finish = try section(in: manager, from: "private func finishSavedPlaybackPositionRestore", until: "private func cancelSavedPlaybackPositionRestore(for player:")
        let capture = try section(in: manager, from: "private func capturePlaybackPositions()", until: "private func ensureResumePositionTimer")
        let termination = try section(in: manager, from: "func prepareForAppTermination()", until: "/// 仅拆掉本机 AVPlayer")
        let grid = try String(
            contentsOf: repoRoot.appendingPathComponent("Components/ExploreGrid/ExploreGridCoordinator.swift"),
            encoding: .utf8
        )
        let bridge = try String(
            contentsOf: repoRoot.appendingPathComponent("Services/WallpaperEngineXBridge.swift"),
            encoding: .utf8
        )
        try expect(!grid.contains("override func tile()"), "production grid has no recursive tile override")
        try expect(grid.contains("let invisibleV = ExploreGridInvisibleScroller()"),
                   "production invisible scrollers remain configured")
        try expect(restore.contains("seenPlayerIDs.insert(playerID).inserted"), "shared decoder seeks once")
        try expect(restore.contains("pendingPlaybackResumes[playerID]?.token == token"), "stale task token is checked")
        try expect(restore.contains("self.players[screenID] === player"), "player identity is checked before seek")
        try expect(restore.contains("self.anchoredVideoPath(for: player) == path"), "file identity is checked before seek")
        try expect(restore.contains("try? await Task.sleep"), "restore waits for Looper's actual queued item")
        try expect(finish.contains("pendingPlaybackResumes.removeValue(forKey: playerID)"), "completion releases play gate")
        try expect(capture.contains("guard !players.isEmpty else"), "empty player set cannot write an empty history")
        try expect(capture.contains("invalidateResumePositionTimer()"), "empty player set stops the sampling timer")
        try expect(termination.contains("capturePlaybackPositions()") && termination.contains("cancelSavedPlaybackPositionRestore()"),
                   "termination takes a final sample and cancels stale seeks")
        let logOffset = try range(of: "AppLogger.error(.wallpaper, \"wallpaper-wgpu 进程已退出\"", in: bridge).lowerBound
        let tableOffset = try range(of: "guard let screenEntry else", in: bridge).lowerBound
        try expect(logOffset < tableOffset, "renderer exits are logged before the early-untracked return")
        try expect(bridge.contains("\"expected\": intentionalTermination && !watchdogTermination"),
                   "expected renderer exits are distinguished from crashes")
        print("PlaybackResumeRegression: \(checks) checks passed; production policy and ownership contracts")
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func section(in source: String, from start: String, until end: String) throws -> String {
        let startRange = try range(of: start, in: source)
        let endRange = try range(of: end, in: source, after: startRange.upperBound)
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private static func range(of needle: String, in source: String, after: String.Index? = nil) throws -> Range<String.Index> {
        guard let found = source.range(of: needle, range: (after ?? source.startIndex)..<source.endIndex) else {
            throw Failure.missing(needle)
        }
        return found
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else { throw Failure.failed(message) }
    }

    private enum Failure: Error, CustomStringConvertible {
        case failed(String)
        case missing(String)
        var description: String {
            switch self {
            case .failed(let message): "FAIL: \(message)"
            case .missing(let anchor): "FAIL: missing production source anchor \(anchor)"
            }
        }
    }
}
