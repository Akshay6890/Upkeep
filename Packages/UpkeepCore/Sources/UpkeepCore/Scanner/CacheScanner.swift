import Foundation

/// Per-application cache folders directly inside ~/Library/Caches. Each folder is
/// its own candidate; the Caches folder itself is never removed.
public struct CacheScanner: CleanupScanner {
    public let category = CleanupCategory.applicationCaches

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        var issues = ScanSupport.IssueCollector(category: category)
        let root = ApprovedRoot(kind: .caches, url: context.environment.caches)
        guard context.fileSystem.exists(root.url) else {
            return .unavailable(category, reason: "~/Library/Caches doesn't exist.")
        }
        let items = ScanSupport.scanChildren(
            of: root, rule: RuleBook.rule(for: .applicationCache), context: context, issues: &issues
        )
        return CategoryResult(category: category, items: items, issues: issues.finish())
    }
}
