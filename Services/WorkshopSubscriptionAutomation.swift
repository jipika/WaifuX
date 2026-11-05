import Foundation

/// Steam 订阅与本地资源联动。偏好由 WaifuXPreferences 同步到 Helper，
/// 因此 UI 排队下载和后台恢复下载使用同一份开关值。
enum WorkshopSubscriptionAutomation {
    static let defaultsKey = "workshop_subscription_automation_enabled"

    static func isEnabled(in defaults: UserDefaults = WaifuXPreferences.shared) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func unsubscribeAfterUserDeletion(itemIDs: Set<String>) async -> [String: Error] {
        guard isEnabled() else { return [:] }
        var failures: [String: Error] = [:]
        for itemID in itemIDs.sorted() where itemID.hasPrefix("workshop_") {
            let workshopID = String(itemID.dropFirst("workshop_".count))
            do {
                try await SteamServiceManager.shared.setSubscribed(false, workshopID: workshopID)
            } catch {
                failures[itemID] = error
            }
        }
        return failures
    }

    static func subscribeBeforeDownload(workshopID: String) async throws {
        guard isEnabled() else { return }
        try await SteamServiceManager.shared.setSubscribed(true, workshopID: workshopID)
    }
}
