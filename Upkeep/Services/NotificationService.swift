import Foundation
import UserNotifications
import UpkeepCore

/// Optional, rate-limited notifications after scheduled scans. At most one
/// notification per day, and only above the user's threshold.
enum NotificationService {
    private static let lastNotificationKey = "UpkeepLastNotificationDate"
    private static let minimumInterval: TimeInterval = 24 * 60 * 60

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        } catch {
            UpkeepLog.app.warning("Notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    static func notifyIfUseful(reclaimableBytes: Int64, settings: UpkeepSettings) async {
        guard settings.notifyAfterScheduledScan, reclaimableBytes >= settings.notificationThresholdBytes else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastNotificationKey) as? Date, Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Upkeep"
        content.body = "Upkeep found \(Formatting.bytes(reclaimableBytes)) of reclaimable storage."
        let request = UNNotificationRequest(identifier: "upkeep.scan.summary", content: content, trigger: nil)
        do {
            try await center.add(request)
            defaults.set(Date(), forKey: lastNotificationKey)
        } catch {
            UpkeepLog.app.warning("Couldn't post notification: \(error.localizedDescription)")
        }
    }
}
