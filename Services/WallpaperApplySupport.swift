import Foundation

/// 设置壁纸的分阶段进度，仅用于 UI 状态展示。
enum WallpaperApplyStage: Int, Comparable, Sendable {
    case preparing, renderReady, synchronizing, committing
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

typealias WallpaperApplyStageHandler = @MainActor (WallpaperApplyStage) -> Void

struct WallpaperApplyProgressState: Equatable, Sendable {
    private(set) var requestID: UUID?
    private(set) var stage: WallpaperApplyStage?
    var isApplying: Bool { requestID != nil }
    var isBlocking: Bool { isApplying && stage == .preparing }

    mutating func begin(_ id: UUID) {
        requestID = id
        stage = .preparing
    }

    @discardableResult
    mutating func report(_ next: WallpaperApplyStage, for id: UUID) -> Bool {
        guard requestID == id, stage.map({ next >= $0 }) == true else { return false }
        stage = next
        return true
    }

    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard requestID == id else { return false }
        requestID = nil
        stage = nil
        return true
    }
}

/// 逐屏代次，避免旧任务覆盖新请求。
struct WallpaperTransitionOwnership: Sendable {
    private var generations: [String: UInt64] = [:]

    mutating func begin(screenIDs: Set<String>) -> [String: UInt64] {
        var request: [String: UInt64] = [:]
        for id in screenIDs {
            let value = (generations[id] ?? 0) &+ 1
            generations[id] = value
            request[id] = value
        }
        return request
    }

    func isCurrent(_ request: [String: UInt64]) -> Bool {
        !request.isEmpty && request.allSatisfy { generations[$0.key] == $0.value }
    }

    func isCurrent(_ request: [String: UInt64], screenID: String) -> Bool {
        request[screenID].map { generations[screenID] == $0 } ?? false
    }
}
