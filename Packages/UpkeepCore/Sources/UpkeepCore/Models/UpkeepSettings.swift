import Foundation

public enum ScanFrequency: String, Codable, Sendable, CaseIterable, Identifiable {
    case manual
    case daily
    case weekly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: return "Manually"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    public var interval: TimeInterval? {
        switch self {
        case .manual: return nil
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }
}

public struct UpkeepSettings: Codable, Equatable, Sendable {
    // Scan
    public var scanFrequency: ScanFrequency = .manual
    public var includeDeveloperCaches: Bool = true
    public var includeLogs: Bool = true
    public var includePackageManagerCaches: Bool = true
    public var logMinimumAgeDays: Int = 14
    public var crashReportMinimumAgeDays: Int = 30
    public var temporaryFileMinimumAgeDays: Int = 3
    public var largeFileThresholdBytes: Int64 = 1_000_000_000

    // Cleanup
    public var confirmBeforeCleanup: Bool = true
    public var moveToTrashWhenPossible: Bool = false
    public var showProtectedItems: Bool = false

    // Notifications
    public var notifyAfterScheduledScan: Bool = false
    public var notificationThresholdBytes: Int64 = 1_000_000_000

    // Menu bar
    public var showMenuBarItem: Bool = true

    public init() {}

    public static let ageRange: ClosedRange<Int> = 1...365

    public func isEnabled(_ category: CleanupCategory) -> Bool {
        switch category.group {
        case .general, .largeFiles: return true
        case .logs: return includeLogs
        case .developer: return includeDeveloperCaches
        case .packageManagers: return includePackageManagerCaches
        }
    }

    /// Clamps user-editable values into sane ranges.
    public func normalized() -> UpkeepSettings {
        var copy = self
        copy.logMinimumAgeDays = min(max(logMinimumAgeDays, Self.ageRange.lowerBound), Self.ageRange.upperBound)
        copy.crashReportMinimumAgeDays = min(max(crashReportMinimumAgeDays, Self.ageRange.lowerBound), Self.ageRange.upperBound)
        copy.temporaryFileMinimumAgeDays = min(max(temporaryFileMinimumAgeDays, Self.ageRange.lowerBound), Self.ageRange.upperBound)
        copy.largeFileThresholdBytes = max(largeFileThresholdBytes, 50_000_000)
        return copy
    }

    // Tolerant decoding so that adding settings in future versions never resets existing ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UpkeepSettings.defaults
        scanFrequency = (try? c.decode(ScanFrequency.self, forKey: .scanFrequency)) ?? d.scanFrequency
        includeDeveloperCaches = (try? c.decode(Bool.self, forKey: .includeDeveloperCaches)) ?? d.includeDeveloperCaches
        includeLogs = (try? c.decode(Bool.self, forKey: .includeLogs)) ?? d.includeLogs
        includePackageManagerCaches = (try? c.decode(Bool.self, forKey: .includePackageManagerCaches)) ?? d.includePackageManagerCaches
        logMinimumAgeDays = (try? c.decode(Int.self, forKey: .logMinimumAgeDays)) ?? d.logMinimumAgeDays
        crashReportMinimumAgeDays = (try? c.decode(Int.self, forKey: .crashReportMinimumAgeDays)) ?? d.crashReportMinimumAgeDays
        temporaryFileMinimumAgeDays = (try? c.decode(Int.self, forKey: .temporaryFileMinimumAgeDays)) ?? d.temporaryFileMinimumAgeDays
        largeFileThresholdBytes = (try? c.decode(Int64.self, forKey: .largeFileThresholdBytes)) ?? d.largeFileThresholdBytes
        confirmBeforeCleanup = (try? c.decode(Bool.self, forKey: .confirmBeforeCleanup)) ?? d.confirmBeforeCleanup
        moveToTrashWhenPossible = (try? c.decode(Bool.self, forKey: .moveToTrashWhenPossible)) ?? d.moveToTrashWhenPossible
        showProtectedItems = (try? c.decode(Bool.self, forKey: .showProtectedItems)) ?? d.showProtectedItems
        notifyAfterScheduledScan = (try? c.decode(Bool.self, forKey: .notifyAfterScheduledScan)) ?? d.notifyAfterScheduledScan
        notificationThresholdBytes = (try? c.decode(Int64.self, forKey: .notificationThresholdBytes)) ?? d.notificationThresholdBytes
        showMenuBarItem = (try? c.decode(Bool.self, forKey: .showMenuBarItem)) ?? d.showMenuBarItem
    }

    private static let defaults = UpkeepSettings()
}
