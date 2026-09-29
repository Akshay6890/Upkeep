import Foundation

/// Stale items in the per-user temporary folder (`/var/folders/…/T`). Only items
/// owned by the current user whose newest content is older than the configured
/// age qualify. `/tmp` and other system-managed locations are never scanned.
public struct TemporaryFilesScanner: CleanupScanner {
    public let category = CleanupCategory.temporaryFiles

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        var issues = ScanSupport.IssueCollector(category: category)
        let root = ApprovedRoot(kind: .temporary, url: context.environment.temporaryDirectory)
        guard context.fileSystem.exists(root.url) else {
            return .unavailable(category, reason: "No per-user temporary folder.")
        }
        let items = ScanSupport.scanChildren(
            of: root, rule: RuleBook.rule(for: .staleTemporaryItem), context: context, issues: &issues
        )
        return CategoryResult(category: category, items: items, issues: issues.finish())
    }
}
