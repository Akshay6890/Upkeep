import Foundation

public enum CleanupRuleID: String, Codable, Sendable, CaseIterable {
    case applicationCache
    case userLog
    case crashReport
    case trashItem
    case staleTemporaryItem
    case xcodeDerivedData
    case xcodeArchive
    case xcodeDeviceSupport
    case simulatorCaches
    case unavailableSimulator
    case homebrewCleanup
    case swiftPMCache
    case npmCache
    case yarnCache
    case pnpmStore
    case pipCache
    case pythonBytecode
    case largeFile
}

/// Inputs a rule decides on. The same structure is built at scan time and again
/// immediately before cleanup, so both decisions come from one predicate.
public struct RuleCandidate: Sendable {
    public let url: URL
    public let info: FileInfo
    /// The kind of approved root the item was found under (`nil` for tool-managed items).
    public let rootKind: RootKind?
    /// Path components below the approved root, ending with the item's name.
    public let relativeComponents: [String]
    public let measurement: DiskUsage?
    /// Direct child names, provided only for rules with `needsChildNames`.
    public let childNames: [String]?

    public init(url: URL, info: FileInfo, rootKind: RootKind?, relativeComponents: [String], measurement: DiskUsage? = nil, childNames: [String]? = nil) {
        self.url = url
        self.info = info
        self.rootKind = rootKind
        self.relativeComponents = relativeComponents
        self.measurement = measurement
        self.childNames = childNames
    }

    public var name: String { relativeComponents.last ?? url.lastPathComponent }
    public var depth: Int { relativeComponents.count }

    /// Most recent modification of the item or anything inside it.
    public var newestModification: Date {
        if let newest = measurement?.newestModification, newest > info.modificationDate { return newest }
        return info.modificationDate
    }
}

public struct RuleContext: Sendable {
    public var settings: UpkeepSettings
    public var now: Date
    public var currentUserID: UInt32
    public var runningBundleIdentifiers: Set<String>
    public var homebrewInstalled: Bool

    public init(settings: UpkeepSettings, now: Date = Date(), currentUserID: UInt32, runningBundleIdentifiers: Set<String> = [], homebrewInstalled: Bool = false) {
        self.settings = settings
        self.now = now
        self.currentUserID = currentUserID
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.homebrewInstalled = homebrewInstalled
    }

    func ageInDays(_ date: Date) -> Double {
        now.timeIntervalSince(date) / 86_400
    }
}

public enum RuleVerdict: Equatable, Sendable {
    /// The item may be offered for cleanup at the given risk.
    case candidate(risk: CleanupRisk, reason: String, notes: [String])
    /// The item must never be cleaned; it can be shown read-only.
    case protected(reason: String)
    /// Not relevant to this rule (e.g. too recent). Not shown.
    case ignore(reason: String)

    public var isCandidate: Bool {
        if case .candidate = self { return true }
        return false
    }

    public var explanation: String {
        switch self {
        case .candidate(_, let reason, _), .protected(let reason), .ignore(let reason): return reason
        }
    }
}

public struct CleanupRule: Sendable {
    public enum SensitiveHandling: Sendable {
        /// Items containing credential- or source-control-like names become protected.
        case protect
        /// Such items stay candidates but are raised to Review with a note.
        case note
        /// The rule's location is known to legitimately contain such names (e.g. Git
        /// checkouts of dependencies inside DerivedData).
        case allow
    }

    public let id: CleanupRuleID
    public let category: CleanupCategory
    public let rootKinds: Set<RootKind>
    public let allowedMethods: Set<CleanupMethodKind>
    public let sensitiveHandling: SensitiveHandling
    public let needsMeasurement: Bool
    public let needsChildNames: Bool
    let evaluator: @Sendable (RuleCandidate, RuleContext) -> RuleVerdict

    init(
        id: CleanupRuleID,
        category: CleanupCategory,
        rootKinds: Set<RootKind>,
        allowedMethods: Set<CleanupMethodKind>,
        sensitiveHandling: SensitiveHandling = .protect,
        needsMeasurement: Bool = true,
        needsChildNames: Bool = false,
        evaluator: @escaping @Sendable (RuleCandidate, RuleContext) -> RuleVerdict
    ) {
        self.id = id
        self.category = category
        self.rootKinds = rootKinds
        self.allowedMethods = allowedMethods
        self.sensitiveHandling = sensitiveHandling
        self.needsMeasurement = needsMeasurement
        self.needsChildNames = needsChildNames
        self.evaluator = evaluator
    }

    /// Whether this rule removes files itself (as opposed to delegating to a tool or being informational).
    public var isFileSystemRule: Bool { !rootKinds.isEmpty }

    public func allows(_ method: CleanupMethod) -> Bool {
        allowedMethods.contains(CleanupMethodKind(method))
    }

    public func evaluate(_ candidate: RuleCandidate, context: RuleContext) -> RuleVerdict {
        if candidate.info.isSymlink {
            return .ignore(reason: "Symbolic links are never followed or removed.")
        }
        if SensitiveNames.containsSensitiveComponent(candidate.relativeComponents) {
            return .protected(reason: "The name suggests credentials, keys or source-control data.")
        }
        let verdict = evaluator(candidate, context)
        guard case .candidate(let risk, let reason, var notes) = verdict,
              let match = candidate.measurement?.sensitiveMatches.first else {
            return verdict
        }
        switch sensitiveHandling {
        case .protect:
            return .protected(reason: "Contains “\(match)”, which may hold credentials or source history.")
        case .note:
            notes.append("Contains “\(match)”. Make sure you no longer need it.")
            return .candidate(risk: max(risk, .review), reason: reason, notes: notes)
        case .allow:
            return verdict
        }
    }
}

/// Method families without associated values, used to declare what a rule may do.
public enum CleanupMethodKind: Hashable, Sendable {
    case delete
    case deletePermanently
    case homebrewCleanup
    case npmCacheClean
    case yarnCacheClean
    case pnpmStorePrune
    case simctlDelete
    case revealOnly

    public init(_ method: CleanupMethod) {
        switch method {
        case .delete: self = .delete
        case .deletePermanently: self = .deletePermanently
        case .revealOnly: self = .revealOnly
        case .tool(let command):
            switch command {
            case .homebrewCleanup: self = .homebrewCleanup
            case .npmCacheClean: self = .npmCacheClean
            case .yarnCacheClean: self = .yarnCacheClean
            case .pnpmStorePrune: self = .pnpmStorePrune
            case .simctlDeleteDevice: self = .simctlDelete
            }
        }
    }
}
