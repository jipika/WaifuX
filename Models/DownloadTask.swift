import Foundation

enum DownloadStatus: String, Codable {
    case pending
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

enum DownloadTaskKind: String, Codable {
    case wallpaper
    case media
    case workshop
}

struct DownloadTask: Identifiable, Codable {
    let id: String
    let kind: DownloadTaskKind
    var wallpaper: Wallpaper?
    var mediaItem: MediaItem?
    var workshopItem: MediaItem?  // Workshop 转换后的 MediaItem
    var workshopID: String?        // 原始 Workshop ID
    var progress: Double           // 0.0 - 1.0
    var status: DownloadStatus     // pending, downloading, paused, completed, failed, cancelled
    let createdAt: Date
    var completedAt: Date?
    var lastUpdatedAt: Date

    init(wallpaper: Wallpaper) {
        self.id = "wallpaper.\(wallpaper.id)"
        self.kind = .wallpaper
        self.wallpaper = wallpaper
        self.mediaItem = nil
        self.workshopItem = nil
        self.workshopID = nil
        self.progress = 0.0
        self.status = .pending
        self.createdAt = Date()
        self.completedAt = nil
        self.lastUpdatedAt = Date()
    }

    init(mediaItem: MediaItem) {
        self.id = "media.\(mediaItem.id)"
        self.kind = .media
        self.wallpaper = nil
        self.mediaItem = mediaItem
        self.workshopItem = nil
        self.workshopID = nil
        self.progress = 0.0
        self.status = .pending
        self.createdAt = Date()
        self.completedAt = nil
        self.lastUpdatedAt = Date()
    }

    init(workshopWallpaper: MediaItem) {
        // workshopWallpaper.id 格式为 "workshop_xxx"
        self.id = "workshop.\(workshopWallpaper.id)"
        self.kind = .workshop
        self.wallpaper = nil
        self.mediaItem = nil
        self.workshopItem = workshopWallpaper
        self.workshopID = String(workshopWallpaper.id.dropFirst("workshop_".count))
        self.progress = 0.0
        self.status = .pending
        self.createdAt = Date()
        self.completedAt = nil
        self.lastUpdatedAt = Date()
    }

    var itemID: String {
        switch kind {
        case .wallpaper:
            return wallpaper?.id ?? id.replacingOccurrences(of: "wallpaper.", with: "")
        case .media:
            return mediaItem?.id ?? id.replacingOccurrences(of: "media.", with: "")
        case .workshop:
            return workshopItem?.id ?? workshopID ?? id.replacingOccurrences(of: "workshop.", with: "")
        }
    }

    var title: String {
        switch kind {
        case .wallpaper:
            if let wallpaper, let tagName = wallpaper.primaryTagName {
                return tagName
            }
            if let wallpaper, let username = wallpaper.uploader?.username, !username.isEmpty {
                return username
            }
            return "Wallpaper \(itemID.uppercased())"
        case .media:
            return mediaItem?.title ?? itemID
        case .workshop:
            return workshopItem?.title ?? "Workshop \(itemID)"
        }
    }

    var subtitle: String {
        switch kind {
        case .wallpaper:
            return wallpaper?.categoryDisplayName ?? ""
        case .media:
            return mediaItem?.subtitle ?? ""
        case .workshop:
            return workshopItem?.subtitle ?? "Steam Workshop"
        }
    }

    var badgeText: String {
        switch kind {
        case .wallpaper:
            return wallpaper?.resolution ?? ""
        case .media:
            return mediaItem?.resolutionLabel ?? ""
        case .workshop:
            return workshopItem?.resolutionLabel ?? "Workshop"
        }
    }

    var thumbnailURL: URL? {
        switch kind {
        case .wallpaper:
            return wallpaper?.thumbURL ?? wallpaper?.smallThumbURL
        case .media:
            return mediaItem?.posterURL ?? mediaItem?.thumbnailURL
        case .workshop:
            return workshopItem?.posterURL ?? workshopItem?.thumbnailURL
        }
    }

    var isRunning: Bool {
        status == .pending || status == .downloading
    }

    var shouldAppearInLibrary: Bool {
        status == .pending || status == .downloading || status == .paused
    }

    var isTerminal: Bool {
        status == .completed || status == .failed || status == .cancelled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case wallpaper
        case mediaItem
        case workshopItem
        case workshopID
        case progress
        case status
        case createdAt
        case completedAt
        case lastUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
        let decodedWallpaper = try container.decodeIfPresent(Wallpaper.self, forKey: .wallpaper)
        let decodedMediaItem = try container.decodeIfPresent(MediaItem.self, forKey: .mediaItem)
        let decodedWorkshopItem = try container.decodeIfPresent(MediaItem.self, forKey: .workshopItem)
        let decodedWorkshopID = try container.decodeIfPresent(String.self, forKey: .workshopID)

        if let decodedKind = try container.decodeIfPresent(DownloadTaskKind.self, forKey: .kind) {
            kind = decodedKind
        } else if decodedWorkshopItem != nil || decodedWorkshopID != nil {
            kind = .workshop
        } else if decodedMediaItem != nil {
            kind = .media
        } else {
            kind = .wallpaper
        }

        id = decodedID
        wallpaper = decodedWallpaper
        mediaItem = decodedMediaItem
        workshopItem = decodedWorkshopItem
        workshopID = decodedWorkshopID
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0.0
        status = try container.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? .pending
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt) ?? completedAt ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(wallpaper, forKey: .wallpaper)
        try container.encodeIfPresent(mediaItem, forKey: .mediaItem)
        try container.encodeIfPresent(workshopItem, forKey: .workshopItem)
        try container.encodeIfPresent(workshopID, forKey: .workshopID)
        try container.encode(progress, forKey: .progress)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
    }
}
