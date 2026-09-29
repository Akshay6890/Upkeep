import Foundation

/// Items in ~/.Trash. Cleaning them is permanent, so every item is Review.
public struct TrashScanner: CleanupScanner {
    public let category = CleanupCategory.trash

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        var issues = ScanSupport.IssueCollector(category: category)
        let root = ApprovedRoot(kind: .trash, url: context.environment.trash)
        guard context.fileSystem.exists(root.url) else {
            return CategoryResult(category: category, items: [])
        }
        let items = ScanSupport.scanChildren(
            of: root, rule: RuleBook.rule(for: .trashItem), context: context, issues: &issues,
            methodFor: { _ in .deletePermanently }, includeEmpty: true
        )
        return CategoryResult(category: category, items: items, issues: issues.finish())
    }
}
