import Foundation
import OSLog

/// 源信誉分：跨会话记录每个规则源的真实播放成败，供排序与默认选源使用。
/// 「可播放」不再只靠本会话内存——上次试出来的好源，这次开窗直接排前面。
/// 衰减：超过 14 天未更新的记录权重减半，超过 60 天视为过期不参与排序。
@MainActor
final class AnimeSourceReputationStore {
    static let shared = AnimeSourceReputationStore()
    private static let logger = Logger(subsystem: "com.waifux.app", category: "AnimeSourceReputation")
    private static let storageKey = "anime_source_reputation_v1"

    struct Record: Codable {
        var successCount: Int = 0
        var failureCount: Int = 0
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var updatedAt: Date = Date()
    }

    private var records: [String: Record] = [:]
    private var loaded = false

    private init() {}

    // MARK: - 记录

    func recordSuccess(sourceID: String) {
        loadIfNeeded()
        var record = records[sourceID] ?? Record()
        record.successCount += 1
        record.lastSuccessAt = Date()
        record.updatedAt = Date()
        records[sourceID] = record
        save()
    }

    func recordFailure(sourceID: String) {
        loadIfNeeded()
        var record = records[sourceID] ?? Record()
        record.failureCount += 1
        record.lastFailureAt = Date()
        record.updatedAt = Date()
        records[sourceID] = record
        save()
    }

    // MARK: - 查询

    /// 信誉分：成功加权 - 失败加权，按时间衰减。无记录返回 0。
    /// 排序用：分高优先；同分按最近成功时间。
    func score(for sourceID: String) -> Double {
        loadIfNeeded()
        guard let record = records[sourceID] else { return 0 }
        let age = Date().timeIntervalSince(record.updatedAt)
        let decay: Double = age > 60 * 86400 ? 0 : (age > 14 * 86400 ? 0.5 : 1)
        guard decay > 0 else { return 0 }
        // 成功权重高于失败：一次真实起播比一次失败更有信息量（失败可能是单集问题）。
        return (Double(record.successCount) * 2 - Double(record.failureCount)) * decay
    }

    /// 是否有过真实起播成功（60 天内）。
    func hasVerifiedPlayback(sourceID: String) -> Bool {
        loadIfNeeded()
        guard let record = records[sourceID], let last = record.lastSuccessAt else { return false }
        return Date().timeIntervalSince(last) < 60 * 86400
    }

    func lastSuccessDate(sourceID: String) -> Date? {
        loadIfNeeded()
        return records[sourceID]?.lastSuccessAt
    }

    /// 排序比较器：信誉分降序 → 最近成功降序 → 规则原顺序。
    /// 返回 true 表示 a 应排在 b 前。
    func ranksBefore(_ a: String, _ b: String) -> Bool {
        let sa = score(for: a), sb = score(for: b)
        if sa != sb { return sa > sb }
        let da = lastSuccessDate(sourceID: a) ?? .distantPast
        let db = lastSuccessDate(sourceID: b) ?? .distantPast
        return da > db
    }

    // MARK: - 持久化

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = WaifuXPreferences.shared.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        WaifuXPreferences.shared.set(data, forKey: Self.storageKey)
    }

    /// 清理过期记录（>180 天未更新），防止无限增长。
    func prune() {
        loadIfNeeded()
        let cutoff = Date().addingTimeInterval(-180 * 86400)
        let before = records.count
        records = records.filter { $0.value.updatedAt > cutoff }
        if records.count != before { save() }
    }
}