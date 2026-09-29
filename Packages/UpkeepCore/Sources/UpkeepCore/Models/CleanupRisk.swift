import Foundation

/// How confident Upkeep is that an item can be removed without losing anything
/// the user cares about.
///
/// - `safe`: regenerable data (caches, stale temporary files, old logs). Selected by default.
/// - `review`: probably removable, but the user must look at it first. Never selected by default.
/// - `protected`: never cleaned. Only shown (read-only) when the user asks to see protected items.
public enum CleanupRisk: String, Codable, Sendable, CaseIterable, Comparable {
    case safe
    case review
    case protected

    private var rank: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        case .protected: return 2
        }
    }

    public static func < (lhs: CleanupRisk, rhs: CleanupRisk) -> Bool {
        lhs.rank < rhs.rank
    }

    public var title: String {
        switch self {
        case .safe: return "Safe to remove"
        case .review: return "Review before removing"
        case .protected: return "Protected"
        }
    }

    public var shortTitle: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .protected: return "Protected"
        }
    }

    public var symbolName: String {
        switch self {
        case .safe: return "checkmark.shield"
        case .review: return "exclamationmark.triangle"
        case .protected: return "lock.shield"
        }
    }

    /// Whether items at this risk level are pre-selected after a scan.
    public var isSelectedByDefault: Bool { self == .safe }
}
