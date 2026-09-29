import Foundation

/// Old log files in ~/Library/Logs (excluding DiagnosticReports, which the crash
/// report scanner handles). Only files older than the configured age qualify.
public struct LogsScanner: CleanupScanner {
    public let category = CleanupCategory.logs
    static let maxDepth = 8

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        var issues = ScanSupport.IssueCollector(category: category)
        let root = ApprovedRoot(kind: .logs, url: context.environment.logs)
        guard context.fileSystem.exists(root.url) else {
            return .unavailable(category, reason: "~/Library/Logs doesn't exist.")
        }
        let rule = RuleBook.rule(for: .userLog)
        var items: [CleanupItem] = []
        var collected = issues
        ScanSupport.walkFiles(
            in: root.url, maxDepth: Self.maxDepth, context: context, issues: &collected,
            skipDirectory: { _, components in components == ["DiagnosticReports"] }
        ) { url, info, components in
            if let item = ScanSupport.evaluate(
                url: url, info: info, root: root, relativeComponents: components,
                rule: rule, context: context, issues: &issues,
                nameFor: { candidate in candidate.relativeComponents.joined(separator: " › ") }
            ) {
                items.append(item)
            }
        }
        let walkIssues = collected.finish()
        return CategoryResult(category: category, items: items, issues: walkIssues + issues.finish())
    }
}

/// Old crash, hang and diagnostic reports in ~/Library/Logs/DiagnosticReports.
public struct CrashReportsScanner: CleanupScanner {
    public let category = CleanupCategory.crashReports

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        var issues = ScanSupport.IssueCollector(category: category)
        let root = ApprovedRoot(kind: .diagnosticReports, url: context.environment.diagnosticReports)
        guard context.fileSystem.exists(root.url) else {
            return .unavailable(category, reason: "No diagnostic reports folder.")
        }
        let rule = RuleBook.rule(for: .crashReport)
        var items: [CleanupItem] = []
        var collected = issues
        ScanSupport.walkFiles(in: root.url, maxDepth: 2, context: context, issues: &collected) { url, info, components in
            let application = RuleBook.applicationName(fromReportName: url.lastPathComponent)
            if let item = ScanSupport.evaluate(
                url: url, info: info, root: root, relativeComponents: components,
                rule: rule, context: context, issues: &issues,
                extraNotes: ["Application: \(application)"]
            ) {
                items.append(item)
            }
        }
        let walkIssues = collected.finish()
        return CategoryResult(category: category, items: items, issues: walkIssues + issues.finish())
    }
}
