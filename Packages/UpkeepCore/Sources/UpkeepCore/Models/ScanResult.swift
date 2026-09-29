import Foundation

public struct ScanIssue: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case permissionDenied
        case notFound
        case toolFailed
        case skipped
        case other
    }

    public let id: UUID
    public let category: CleanupCategory
    public let kind: Kind
    public let path: String?
    public let message: String
    /// For aggregated issues: how many paths this entry stands for.
    public let count: Int

    public init(category: CleanupCategory, kind: Kind, path: String?, message: String, count: Int = 1) {
        self.id = UUID()
        self.category = category
        self.kind = kind
        self.path = path
        self.message = message
        self.count = count
    }
}

public struct CategoryResult: Identifiable, Codable, Hashable, Sendable {
    public var id: CleanupCategory { category }
    public let category: CleanupCategory
    /// `false` when the category doesn't apply to this Mac (e.g. Homebrew isn't installed).
    public let isAvailable: Bool
    public let unavailableReason: String?
    public var items: [CleanupItem]
    public var issues: [ScanIssue]

    public init(category: CleanupCategory, items: [CleanupItem], issues: [ScanIssue] = []) {
        self.category = category
        self.isAvailable = true
        self.unavailableReason = nil
        self.items = items.sorted { $0.size > $1.size }
        self.issues = issues
    }

    public static func unavailable(_ category: CleanupCategory, reason: String) -> CategoryResult {
        CategoryResult(category: category, isAvailable: false, unavailableReason: reason)
    }

    private init(category: CleanupCategory, isAvailable: Bool, unavailableReason: String?) {
        self.category = category
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.items = []
        self.issues = []
    }

    public var cleanableItems: [CleanupItem] { items.filter(\.isCleanable) }
    public var cleanableSize: Int64 { cleanableItems.reduce(0) { $0 + $1.size } }
    public var cleanableFileCount: Int { cleanableItems.reduce(0) { $0 + $1.fileCount } }

    /// The most cautious risk level among cleanable items.
    public var highestCleanableRisk: CleanupRisk? { cleanableItems.map(\.risk).max() }
}

public struct ScanResult: Codable, Hashable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public var categories: [CategoryResult]
    public let wasCancelled: Bool

    public init(startedAt: Date, finishedAt: Date, categories: [CategoryResult], wasCancelled: Bool = false) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.categories = categories.sorted { $0.category < $1.category }
        self.wasCancelled = wasCancelled
    }

    public var availableCategories: [CategoryResult] { categories.filter(\.isAvailable) }
    public var allItems: [CleanupItem] { categories.flatMap(\.items) }
    public var issues: [ScanIssue] { categories.flatMap(\.issues) }

    public var reclaimableBytes: Int64 { categories.reduce(0) { $0 + $1.cleanableSize } }

    public func reclaimableBytes(risk: CleanupRisk) -> Int64 {
        allItems.filter { $0.isCleanable && $0.risk == risk }.reduce(0) { $0 + $1.size }
    }

    public func result(for category: CleanupCategory) -> CategoryResult? {
        categories.first { $0.category == category }
    }
}
