import Foundation

/// Files in the home folder at or above the size threshold. Informational only:
/// every item uses `.revealOnly` and cannot be cleaned by Upkeep.
public struct LargeFilesScanner: CleanupScanner {
    public let category = CleanupCategory.largeFiles
    static let maxDepth = 32
    static let maxResults = 1_000
    /// Directories treated as opaque documents rather than folders to descend into.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "fcpbundle", "logicx",
        "imovielibrary", "band", "xcarchive", "framework", "bundle", "plugin", "kext", "appex", "xcodeproj", "xcworkspace",
    ]
    static let skippedTopLevel: Set<String> = ["Library", ".Trash"]
    static let skippedNames: Set<String> = [".git", "node_modules", ".build", "DerivedData"]

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        let env = context.environment
        let threshold = context.settings.largeFileThresholdBytes
        let rule = RuleBook.rule(for: .largeFile)
        var issues = ScanSupport.IssueCollector(category: category)
        var items: [CleanupItem] = []

        ScanSupport.walkFiles(
            in: env.homeDirectory, maxDepth: Self.maxDepth, context: context, issues: &issues,
            skipDirectory: { url, components in
                if components.count == 1 && Self.skippedTopLevel.contains(url.lastPathComponent) { return true }
                if Self.skippedNames.contains(url.lastPathComponent) { return true }
                return Self.packageExtensions.contains(url.pathExtension.lowercased())
            }
        ) { url, info, _ in
            context.progress.analyzed(1)
            guard !info.isDataless, info.allocatedSize >= threshold else { return }
            let candidate = RuleCandidate(url: url, info: info, rootKind: nil, relativeComponents: [url.lastPathComponent])
            guard case .candidate(let risk, let reason, let notes) = rule.evaluate(candidate, context: context.ruleContext) else { return }
            items.append(CleanupItem(
                name: url.lastPathComponent,
                url: url,
                category: category,
                risk: risk,
                ruleID: .largeFile,
                reason: reason,
                source: env.displayPath(url.deletingLastPathComponent()),
                rootURL: nil,
                method: .revealOnly,
                size: info.allocatedSize,
                fileCount: 1,
                modifiedDate: info.modificationDate,
                identity: info.identity,
                notes: notes
            ))
        }

        items.sort { $0.size > $1.size }
        if items.count > Self.maxResults {
            items = Array(items.prefix(Self.maxResults))
        }
        return CategoryResult(category: category, items: items, issues: issues.finish())
    }
}
