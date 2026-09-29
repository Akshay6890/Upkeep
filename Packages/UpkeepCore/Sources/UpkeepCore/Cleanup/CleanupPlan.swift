import Foundation

/// What a cleanup would do, computed before anything is touched.
public struct CleanupPlan: Identifiable, Sendable, Equatable {
    public struct Group: Identifiable, Sendable, Equatable {
        public var id: CleanupCategory { category }
        public let category: CleanupCategory
        public let items: [CleanupItem]
        public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
        public var highestRisk: CleanupRisk { items.map(\.risk).max() ?? .safe }
    }

    /// Items that will be processed.
    public let items: [CleanupItem]
    /// Items that were requested but can't be cleaned (protected or informational).
    public let excluded: [CleanupItem]
    public let groups: [Group]

    public init(selection: [CleanupItem]) {
        var seen = Set<String>()
        var accepted: [CleanupItem] = []
        var rejected: [CleanupItem] = []
        for item in selection where seen.insert(item.id).inserted {
            if item.isCleanable && RuleBook.rule(for: item.ruleID).allows(item.method) && RuleBook.rule(for: item.ruleID).category == item.category {
                accepted.append(item)
            } else {
                rejected.append(item)
            }
        }
        self.items = accepted
        self.excluded = rejected
        self.groups = Dictionary(grouping: accepted, by: \.category)
            .map { Group(category: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.category < $1.category }
    }

    public var id: [String] { items.map(\.id) }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    public var permanentBytes: Int64 { items.filter(\.isPermanent).reduce(0) { $0 + $1.size } }
    public var reviewItemCount: Int { items.filter { $0.risk == .review }.count }
    public var isEmpty: Bool { items.isEmpty }

    public var toolCommands: [ToolCommand] {
        var commands: [ToolCommand] = []
        for item in items {
            if case .tool(let command) = item.method, !commands.contains(command) { commands.append(command) }
        }
        return commands
    }

    /// Plain-language warnings to show before confirming.
    public var warnings: [String] {
        var result: [String] = []
        if permanentBytes > 0 {
            result.append("\(Formatting.bytes(permanentBytes)) from the Trash will be deleted permanently. This can't be undone.")
        }
        if reviewItemCount > 0 {
            result.append("\(Formatting.plural(reviewItemCount, "selected item")) marked Review. Make sure you no longer need \(reviewItemCount == 1 ? "it" : "them").")
        }
        let running = items.filter { $0.notes.contains { $0.contains("is running") } }
        if !running.isEmpty {
            result.append("\(Formatting.plural(running.count, "item")) belong to apps that are running. Quit them first for best results.")
        }
        if !toolCommands.isEmpty {
            result.append("Upkeep will run: " + toolCommands.map(\.displayCommand).joined(separator: ", ") + ".")
        }
        return result
    }
}

public enum CleanupOutcome: Codable, Hashable, Sendable {
    case removed(freedBytes: Int64, note: String?)
    case movedToTrash(bytes: Int64)
    case wouldRemove(bytes: Int64)
    case partial(freedBytes: Int64, reason: String)
    case skipped(reason: String)
    case failed(reason: String)

    public var freedBytes: Int64 {
        switch self {
        case .removed(let bytes, _), .partial(let bytes, _): return bytes
        default: return 0
        }
    }

    public var isSuccess: Bool {
        switch self {
        case .removed, .movedToTrash, .wouldRemove: return true
        default: return false
        }
    }

    public var summary: String {
        switch self {
        case .removed(let bytes, let note): return "Removed \(Formatting.bytes(bytes))" + (note.map { ". \($0)" } ?? "")
        case .movedToTrash(let bytes): return "Moved \(Formatting.bytes(bytes)) to the Trash"
        case .wouldRemove(let bytes): return "Would remove \(Formatting.bytes(bytes))"
        case .partial(let bytes, let reason): return "Partially removed (\(Formatting.bytes(bytes))): \(reason)"
        case .skipped(let reason): return "Skipped: \(reason)"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

public struct CleanupItemResult: Identifiable, Codable, Hashable, Sendable {
    public var id: String { item.id }
    public let item: CleanupItem
    public let outcome: CleanupOutcome
}

public struct CleanupProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var currentItemName: String?
    public var currentOperation: String?
    public var bytesReclaimed: Int64

    public var fractionComplete: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

public struct CleanupReport: Codable, Hashable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let dryRun: Bool
    public let results: [CleanupItemResult]

    public var reclaimedBytes: Int64 { results.reduce(0) { $0 + $1.outcome.freedBytes } }

    public var movedToTrashBytes: Int64 {
        results.reduce(0) { total, result in
            if case .movedToTrash(let bytes) = result.outcome { return total + bytes }
            return total
        }
    }

    public var wouldReclaimBytes: Int64 {
        results.reduce(0) { total, result in
            if case .wouldRemove(let bytes) = result.outcome { return total + bytes }
            return total
        }
    }

    public var succeeded: [CleanupItemResult] { results.filter { $0.outcome.isSuccess } }
    public var skipped: [CleanupItemResult] {
        results.filter { if case .skipped = $0.outcome { return true } else { return false } }
    }
    public var failed: [CleanupItemResult] {
        results.filter {
            switch $0.outcome {
            case .failed, .partial: return true
            default: return false
            }
        }
    }
}

public enum VerificationStatus: Equatable, Sendable {
    /// Nothing exists at the path any more.
    case removed
    /// The same item (same identity) is still there.
    case stillPresent(remainingBytes: Int64)
    /// A new item exists at the path — typically an app recreated its cache.
    case recreated(currentBytes: Int64)
}
