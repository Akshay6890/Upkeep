import Foundation

/// Commands Upkeep may run on behalf of a developer tool. This is a closed set:
/// there is no way to construct an arbitrary command line, and the executable
/// is always resolved from a fixed list of trusted locations at run time.
public enum ToolCommand: Codable, Hashable, Sendable {
    /// `brew cleanup`
    case homebrewCleanup
    /// `npm cache clean --force`
    case npmCacheClean
    /// `yarn cache clean`
    case yarnCacheClean
    /// `pnpm store prune`
    case pnpmStorePrune
    /// `xcrun simctl delete <udid>` for a simulator whose runtime is unavailable.
    case simctlDeleteDevice(udid: String)

    public var displayCommand: String {
        switch self {
        case .homebrewCleanup: return "brew cleanup"
        case .npmCacheClean: return "npm cache clean --force"
        case .yarnCacheClean: return "yarn cache clean"
        case .pnpmStorePrune: return "pnpm store prune"
        case .simctlDeleteDevice(let udid): return "xcrun simctl delete \(udid)"
        }
    }
}

public enum CleanupMethod: Codable, Hashable, Sendable {
    /// Remove the item. Honors the "Move to Trash when possible" setting.
    case delete
    /// Remove the item permanently (used for items that are already in the Trash).
    case deletePermanently
    /// Ask the owning tool to clean up.
    case tool(ToolCommand)
    /// Informational only. Upkeep will not remove this item.
    case revealOnly

    public var isPermanent: Bool {
        switch self {
        case .deletePermanently: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .delete: return "Remove"
        case .deletePermanently: return "Delete permanently"
        case .tool(let command): return "Run \(command.displayCommand)"
        case .revealOnly: return "Not removable"
        }
    }
}

/// The on-disk identity of an item at scan time, used to detect items that were
/// replaced between scanning and cleaning.
public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct CleanupItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let category: CleanupCategory
    public let risk: CleanupRisk
    public let ruleID: CleanupRuleID
    /// Why this item is a candidate (or why it is protected).
    public let reason: String
    /// Where the item was found, e.g. "~/Library/Caches".
    public let source: String
    /// The approved cleanup root the item lives in. `nil` for tool-managed items.
    public let rootURL: URL?
    public let method: CleanupMethod
    /// Bytes on disk (allocated size), or the tool's own estimate for tool-managed items.
    public let size: Int64
    public let fileCount: Int
    public let modifiedDate: Date?
    public let identity: FileIdentity?
    /// Extra information for the user, e.g. "App is running" or a size breakdown.
    public let notes: [String]
    /// For tool-managed items: the paths the tool reported it would remove (capped).
    public let detailPaths: [String]

    public init(
        name: String,
        url: URL,
        category: CleanupCategory,
        risk: CleanupRisk,
        ruleID: CleanupRuleID,
        reason: String,
        source: String,
        rootURL: URL?,
        method: CleanupMethod,
        size: Int64,
        fileCount: Int,
        modifiedDate: Date?,
        identity: FileIdentity?,
        notes: [String] = [],
        detailPaths: [String] = [],
        idSuffix: String? = nil
    ) {
        self.id = "\(ruleID.rawValue):\(url.path)" + (idSuffix.map { "#\($0)" } ?? "")
        self.name = name
        self.url = url
        self.category = category
        self.risk = risk
        self.ruleID = ruleID
        self.reason = reason
        self.source = source
        self.rootURL = rootURL
        self.method = method
        self.size = size
        self.fileCount = fileCount
        self.modifiedDate = modifiedDate
        self.identity = identity
        self.notes = notes
        self.detailPaths = detailPaths
    }

    /// Whether Upkeep is able to clean this item at all.
    public var isCleanable: Bool {
        guard risk != .protected else { return false }
        if case .revealOnly = method { return false }
        return true
    }

    public var isPermanent: Bool { method.isPermanent }
}
