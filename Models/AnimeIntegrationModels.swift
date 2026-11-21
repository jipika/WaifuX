import Foundation

struct BangumiAccountUser: Decodable, Equatable {
    let id: Int
    let username: String
    let nickname: String?
}

enum BangumiSyncConflictPolicy: String, CaseIterable, Identifiable {
    case newest, local, remote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: return t("较新的状态优先（同时间保留本地）")
        case .local: return t("保留本地状态")
        case .remote: return t("使用 Bangumi 状态")
        }
    }
}

struct BangumiAccountCollection: Decodable {
    struct Subject: Decodable {
        struct Images: Decodable {
            let common: String?
            let medium: String?
            let large: String?
        }
        let id: Int
        let name: String?
        let nameCN: String?
        let images: Images?
        enum CodingKeys: String, CodingKey { case id, name, images; case nameCN = "name_cn" }
    }
    let subjectID: Int
    let type: Int
    let updatedAt: String
    let subject: Subject?
    enum CodingKeys: String, CodingKey {
        case type, subject
        case subjectID = "subject_id"
        case updatedAt = "updated_at"
    }

    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt)
    }

    var watchStatus: FavoriteAnime.WatchStatus? {
        switch type {
        case 1: return .planToWatch
        case 2: return .completed
        case 3: return .watching
        case 4: return .onHold
        case 5: return .dropped
        default: return nil
        }
    }

    static func remoteType(_ status: FavoriteAnime.WatchStatus) -> Int {
        switch status {
        case .planToWatch: return 1
        case .completed: return 2
        case .watching: return 3
        case .onHold: return 4
        case .dropped: return 5
        }
    }

    /// Remote timestamp is a collection update, not the original date of adding an existing local item.
    func merged(with local: FavoriteAnime?, policy: BangumiSyncConflictPolicy) -> FavoriteAnime? {
        guard subjectID > 0, let status = watchStatus, let remoteDate = date else { return nil }
        func nonempty(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        let remoteTitle = nonempty(subject?.nameCN) ?? nonempty(subject?.name)
        guard let title = nonempty(local?.title) ?? remoteTitle else { return nil }
        let remoteWins = local == nil || policy == .remote || (policy == .newest && remoteDate > local!.updatedAt)
        let cover = nonempty(local?.coverURL) ?? nonempty(subject?.images?.common)
            ?? nonempty(subject?.images?.medium) ?? nonempty(subject?.images?.large)
        return FavoriteAnime(
            id: local?.id ?? "bangumi_\(subjectID)", title: title,
            originalTitle: nonempty(local?.originalTitle) ?? nonempty(subject?.name),
            coverURL: cover, bangumiId: subjectID,
            addedAt: local?.addedAt ?? remoteDate,
            updatedAt: remoteWins ? remoteDate : (local?.updatedAt ?? remoteDate),
            note: local?.note, tags: local?.tags ?? [], score: local?.score,
            watchStatus: remoteWins ? status : (local?.watchStatus ?? status)
        )
    }
}

struct BangumiSyncReport {
    var succeeded = 0
    var skipped = 0
    var failures: [String] = []
    var summary: String { String(format: t("成功 %d 项，跳过 %d 项，失败 %d 项"), succeeded, skipped, failures.count) }
}

enum AnimeSyncPlayConnectionState: Equatable {
    case disconnected, connecting, securing, joining, connected, reconnecting(Int), failed
    var label: String {
        switch self {
        case .disconnected: return t("未连接")
        case .connecting: return t("连接中")
        case .securing: return t("TLS 握手中")
        case .joining: return t("等待房间确认")
        case .connected: return t("已加入房间")
        case .reconnecting(let attempt): return String(format: t("重新连接（%d/3）"), attempt)
        case .failed: return t("连接失败")
        }
    }
}

struct AnimeSyncPlayMessage: Identifiable {
    let id = UUID()
    let date = Date()
    let username: String
    let text: String
    let isSystem: Bool
}

struct AnimeSyncPlayEndpoint: Equatable {
    // Fixed upstream lib/services/player/syncplay_endpoint.dart, commit 0685a364f17f02735dc8a5ffc47a1330e36d0d6a.
    static let upstreamDefault = "syncplay.pl:8996"
    let host: String
    let port: UInt16
    let requiresTLS: Bool

    init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitTLS = trimmed.hasPrefix("syncplays://")
        let plain = explicitTLS ? String(trimmed.dropFirst("syncplays://".count)) : trimmed
        guard !plain.contains("/"), !plain.contains("@"), !plain.contains("?"), !plain.contains("#") else { return nil }
        let hostPart: String
        let portPart: String
        if plain.hasPrefix("[") {
            guard let closing = plain.firstIndex(of: "]"), plain.index(after: closing) < plain.endIndex,
                  plain[plain.index(after: closing)] == ":" else { return nil }
            hostPart = String(plain[plain.index(after: plain.startIndex)..<closing])
            portPart = String(plain[plain.index(closing, offsetBy: 2)...])
        } else {
            guard let colon = plain.lastIndex(of: ":") else { return nil }
            hostPart = String(plain[..<colon])
            portPart = String(plain[plain.index(after: colon)...])
            guard !hostPart.contains(":") else { return nil }
        }
        guard !hostPart.isEmpty, !hostPart.contains(where: { $0.isWhitespace }),
              let port = UInt16(portPart), port > 0 else { return nil }
        host = hostPart
        self.port = port
        requiresTLS = explicitTLS || (hostPart.lowercased() == "syncplay.pl" && (8995...8999).contains(Int(port)))
    }
}
