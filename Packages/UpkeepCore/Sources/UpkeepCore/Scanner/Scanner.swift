import Foundation

/// A deterministic scanner for one cleanup category. Scanners only read; they
/// never modify the file system.
public protocol CleanupScanner: Sendable {
    var category: CleanupCategory { get }
    func scan(_ context: ScanContext) async -> CategoryResult
}

public struct ScanContext: Sendable {
    public let environment: ScanEnvironment
    public let settings: UpkeepSettings
    public let fileSystem: FileSystemService
    public let ruleContext: RuleContext
    public let progress: ScanProgressReporter
    public let toolLocator: ToolLocator
    public let toolRunner: ToolRunning

    public init(
        environment: ScanEnvironment,
        settings: UpkeepSettings,
        fileSystem: FileSystemService,
        ruleContext: RuleContext,
        progress: ScanProgressReporter,
        toolRunner: ToolRunning
    ) {
        self.environment = environment
        self.settings = settings
        self.fileSystem = fileSystem
        self.ruleContext = ruleContext
        self.progress = progress
        self.toolLocator = ToolLocator(environment: environment, fileSystem: fileSystem)
        self.toolRunner = toolRunner
    }
}

public struct ScanProgress: Equatable, Sendable {
    public var currentCategory: CleanupCategory?
    public var itemsAnalyzed: Int = 0
    public var bytesDiscovered: Int64 = 0
    public var currentPath: String?
    public var completedCategories: Int = 0
    public var totalCategories: Int = 0

    public init() {}

    public var fractionComplete: Double {
        guard totalCategories > 0 else { return 0 }
        return min(1, Double(completedCategories) / Double(totalCategories))
    }
}

/// Thread-safe progress sink. Scanners update it from background tasks; the UI
/// samples `snapshot()` on a timer so the main thread is never flooded.
public final class ScanProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var state = ScanProgress()

    public init() {}

    public func snapshot() -> ScanProgress {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func begin(totalCategories: Int) {
        lock.lock()
        state = ScanProgress()
        state.totalCategories = totalCategories
        lock.unlock()
    }

    public func beginCategory(_ category: CleanupCategory) {
        lock.lock()
        state.currentCategory = category
        state.currentPath = nil
        lock.unlock()
    }

    public func finishCategory() {
        lock.lock()
        state.completedCategories += 1
        lock.unlock()
    }

    public func analyzed(_ count: Int = 1, path: String? = nil) {
        lock.lock()
        state.itemsAnalyzed += count
        if let path { state.currentPath = path }
        lock.unlock()
    }

    public func discovered(bytes: Int64) {
        lock.lock()
        state.bytesDiscovered += bytes
        lock.unlock()
    }
}

// MARK: - Shared scanning helpers

enum ScanSupport {
    /// Collects permission problems and other errors into a few user-facing issues.
    struct IssueCollector {
        let category: CleanupCategory
        var issues: [ScanIssue] = []
        var deniedCount = 0
        var errorCount = 0

        init(category: CleanupCategory) {
            self.category = category
        }

        mutating func record(_ error: Error, path: String, environment: ScanEnvironment) {
            let display = environment.displayPath(URL(fileURLWithPath: path))
            if let fsError = error as? FileSystemError {
                switch fsError {
                case .permissionDenied:
                    issues.append(ScanIssue(
                        category: category, kind: .permissionDenied, path: display,
                        message: "macOS denied access to \(display). Grant Upkeep Full Disk Access in System Settings to include it."
                    ))
                    return
                case .notFound:
                    return
                default:
                    break
                }
            }
            issues.append(ScanIssue(category: category, kind: .other, path: display, message: "Couldn't read \(display): \(error)"))
        }

        mutating func absorb(_ measurement: DiskUsage) {
            deniedCount += measurement.permissionDeniedCount
            errorCount += measurement.otherErrorCount
        }

        mutating func finish() -> [ScanIssue] {
            if deniedCount > 0 {
                issues.append(ScanIssue(
                    category: category, kind: .permissionDenied, path: nil,
                    message: "Skipped \(Formatting.plural(deniedCount, "item")) because macOS denied access.",
                    count: deniedCount
                ))
            }
            if errorCount > 0 {
                issues.append(ScanIssue(
                    category: category, kind: .other, path: nil,
                    message: "Skipped \(Formatting.plural(errorCount, "item")) that couldn't be read.",
                    count: errorCount
                ))
            }
            let result = issues
            issues = []
            deniedCount = 0
            errorCount = 0
            return result
        }
    }

    /// Evaluates `rule` for one path and builds an item if it should be shown.
    static func evaluate(
        url: URL,
        info: FileInfo,
        root: ApprovedRoot,
        relativeComponents: [String],
        rule: CleanupRule,
        context: ScanContext,
        issues: inout IssueCollector,
        methodFor: (RuleCandidate) -> CleanupMethod = { _ in .delete },
        nameFor: ((RuleCandidate) -> String)? = nil,
        extraNotes: [String] = [],
        includeEmpty: Bool = false
    ) -> CleanupItem? {
        // Cheap first pass without measuring, to skip obviously irrelevant paths.
        let childNames: [String]? = rule.needsChildNames && info.isDirectory
            ? (try? context.fileSystem.contentsOfDirectory(at: url))?.map(\.lastPathComponent)
            : nil
        let shallow = RuleCandidate(url: url, info: info, rootKind: root.kind, relativeComponents: relativeComponents, childNames: childNames)
        let preliminary = rule.evaluate(shallow, context: context.ruleContext)
        switch preliminary {
        case .ignore:
            // Final: a folder's newest content is never older than the folder itself.
            return nil
        case .protected:
            if !context.settings.showProtectedItems { return nil }
        case .candidate:
            break
        }

        var measurement: DiskUsage?
        if rule.needsMeasurement || info.isDirectory {
            let options = MeasureOptions(detectSensitiveNames: rule.sensitiveHandling != .allow)
            let progress = context.progress
            let m = context.fileSystem.measure(url, options: options) { count, path in
                progress.analyzed(count, path: path)
            }
            issues.absorb(m)
            measurement = m
        } else {
            context.progress.analyzed(1, path: url.path)
        }

        let candidate = RuleCandidate(
            url: url, info: info, rootKind: root.kind, relativeComponents: relativeComponents,
            measurement: measurement, childNames: childNames
        )
        let verdict = rule.evaluate(candidate, context: context.ruleContext)
        let size = measurement?.allocatedBytes ?? info.allocatedSize
        let fileCount = measurement.map { $0.fileCount + $0.symlinkCount } ?? 1
        if !includeEmpty && info.isDirectory && fileCount == 0 { return nil }

        let risk: CleanupRisk
        let reason: String
        var notes: [String]
        let method: CleanupMethod
        switch verdict {
        case .ignore:
            return nil
        case .protected(let why):
            guard context.settings.showProtectedItems else { return nil }
            risk = .protected
            reason = why
            notes = []
            method = .revealOnly
        case .candidate(let r, let why, let n):
            risk = r
            reason = why
            notes = n
            method = methodFor(candidate)
        }
        notes += extraNotes
        if let m = measurement {
            if m.permissionDeniedCount > 0 {
                notes.append("\(Formatting.plural(m.permissionDeniedCount, "item")) inside couldn't be read; the size may be higher.")
            }
            if m.truncated {
                notes.append("Very deep or large folder; the size shown is a lower bound.")
            }
        }
        let item = CleanupItem(
            name: nameFor?(candidate) ?? url.lastPathComponent,
            url: url,
            category: rule.category,
            risk: risk,
            ruleID: rule.id,
            reason: reason,
            source: context.environment.displayPath(root.url),
            rootURL: root.url,
            method: method,
            size: size,
            fileCount: fileCount,
            modifiedDate: measurement?.newestModification ?? info.modificationDate,
            identity: info.identity,
            notes: notes
        )
        if item.isCleanable { context.progress.discovered(bytes: item.size) }
        return item
    }

    /// Applies `rule` to every direct child of `root`.
    static func scanChildren(
        of root: ApprovedRoot,
        directory: URL? = nil,
        parentComponents: [String] = [],
        rule: CleanupRule,
        context: ScanContext,
        issues: inout IssueCollector,
        methodFor: (RuleCandidate) -> CleanupMethod = { _ in .delete },
        includeEmpty: Bool = false
    ) -> [CleanupItem] {
        let directory = directory ?? root.url
        let children: [URL]
        do {
            children = try context.fileSystem.contentsOfDirectory(at: directory)
        } catch {
            issues.record(error, path: directory.path, environment: context.environment)
            return []
        }
        var items: [CleanupItem] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if Task.isCancelled { break }
            let info: FileInfo
            do {
                info = try context.fileSystem.info(at: child)
            } catch {
                issues.record(error, path: child.path, environment: context.environment)
                continue
            }
            context.progress.analyzed(0, path: child.path)
            if let item = evaluate(
                url: child, info: info, root: root,
                relativeComponents: parentComponents + [child.lastPathComponent],
                rule: rule, context: context, issues: &issues,
                methodFor: methodFor, includeEmpty: includeEmpty
            ) {
                items.append(item)
            }
        }
        return items
    }

    /// Recursively yields regular files below `directory` (no symlinks, bounded depth).
    static func walkFiles(
        in directory: URL,
        maxDepth: Int,
        context: ScanContext,
        issues: inout IssueCollector,
        skipDirectory: (URL, [String]) -> Bool = { _, _ in false },
        visit: (URL, FileInfo, [String]) -> Void
    ) {
        var stack: [(URL, [String])] = [(directory, [])]
        while let (current, components) = stack.popLast() {
            if Task.isCancelled { return }
            let children: [URL]
            do {
                children = try context.fileSystem.contentsOfDirectory(at: current)
            } catch {
                issues.record(error, path: current.path, environment: context.environment)
                continue
            }
            context.progress.analyzed(0, path: current.path)
            for child in children {
                let childComponents = components + [child.lastPathComponent]
                guard let info = try? context.fileSystem.info(at: child) else { continue }
                switch info.type {
                case .directory:
                    if childComponents.count < maxDepth && !skipDirectory(child, childComponents) {
                        stack.append((child, childComponents))
                    }
                case .regular:
                    visit(child, info, childComponents)
                case .symlink, .other:
                    continue
                }
            }
        }
    }
}
