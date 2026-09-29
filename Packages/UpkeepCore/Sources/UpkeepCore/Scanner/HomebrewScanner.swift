import Foundation

/// Asks Homebrew itself what `brew cleanup` would remove (`--dry-run`). Upkeep
/// never deletes files inside the Homebrew installation directly.
public struct HomebrewScanner: CleanupScanner {
    public let category = CleanupCategory.homebrew
    static let maxDetailPaths = 500

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        let service = HomebrewService(locator: context.toolLocator, runner: context.toolRunner)
        guard let installation = service.detect() else {
            return .unavailable(category, reason: "Homebrew is not installed.")
        }
        context.progress.analyzed(0, path: installation.executable.path + " cleanup --dry-run")

        let preview: HomebrewCleanupPreview
        do {
            preview = try await service.previewCleanup(installation)
        } catch {
            UpkeepLog.tools.warning("brew cleanup --dry-run failed: \(error)")
            return CategoryResult(category: category, items: [], issues: [
                ScanIssue(category: category, kind: .toolFailed, path: nil, message: "Homebrew couldn't report cleanup candidates: \(error)"),
            ])
        }
        context.progress.analyzed(preview.entries.count)
        guard preview.totalBytes > 0 || !preview.entries.isEmpty else {
            return CategoryResult(category: category, items: [])
        }

        var notes: [String] = []
        let breakdown: [(HomebrewCleanupPreview.EntryKind, String)] = [
            (.cachedDownload, "Cached downloads"),
            (.oldVersion, "Old package versions"),
            (.other, "Other cleanup candidates"),
        ]
        for (kind, label) in breakdown where preview.count(of: kind) > 0 {
            notes.append("\(label): \(Formatting.bytes(preview.bytes(of: kind))) (\(Formatting.plural(preview.count(of: kind), "item")))")
        }
        notes.append("Sizes are Homebrew's own estimates.")

        let item = CleanupItem(
            name: "Homebrew cleanup",
            url: installation.prefix,
            category: category,
            risk: .safe,
            ruleID: .homebrewCleanup,
            reason: "Old versions and stale downloads that `brew cleanup` removes. Installed packages are not affected.",
            source: installation.executable.path,
            rootURL: nil,
            method: .tool(.homebrewCleanup),
            size: preview.totalBytes,
            fileCount: preview.entries.count,
            modifiedDate: nil,
            identity: nil,
            notes: notes,
            detailPaths: preview.entries.prefix(Self.maxDetailPaths).map(\.path)
        )
        context.progress.discovered(bytes: item.size)
        return CategoryResult(category: category, items: [item])
    }
}
