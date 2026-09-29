import Foundation

/// Runs the category scanners one after another, off the main thread, reporting
/// progress as it goes. Scanning never modifies the file system.
public struct ScanCoordinator: Sendable {
    public let environment: ScanEnvironment
    public let settings: UpkeepSettings
    public let fileSystem: FileSystemService
    public let toolRunner: ToolRunning
    public let runningBundleIdentifiers: Set<String>
    public let scanners: [CleanupScanner]

    public static let defaultScanners: [CleanupScanner] = [
        CacheScanner(),
        LogsScanner(),
        CrashReportsScanner(),
        TemporaryFilesScanner(),
        TrashScanner(),
        XcodeScanner(),
        HomebrewScanner(),
        SwiftPackageManagerScanner(),
        NodePackageManagerScanner(),
        PythonCacheScanner(),
    ]

    public init(
        environment: ScanEnvironment,
        settings: UpkeepSettings,
        fileSystem: FileSystemService = LocalFileSystem(),
        toolRunner: ToolRunning = ProcessToolRunner(),
        runningBundleIdentifiers: Set<String> = [],
        scanners: [CleanupScanner] = ScanCoordinator.defaultScanners
    ) {
        self.environment = environment
        self.settings = settings.normalized()
        self.fileSystem = fileSystem
        self.toolRunner = toolRunner
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.scanners = scanners
    }

    public func makeContext(progress: ScanProgressReporter, now: Date = Date()) -> ScanContext {
        let locator = ToolLocator(environment: environment, fileSystem: fileSystem)
        let ruleContext = RuleContext(
            settings: settings,
            now: now,
            currentUserID: environment.currentUserID,
            runningBundleIdentifiers: runningBundleIdentifiers,
            homebrewInstalled: locator.locate(.brew) != nil
        )
        return ScanContext(
            environment: environment, settings: settings, fileSystem: fileSystem,
            ruleContext: ruleContext, progress: progress, toolRunner: toolRunner
        )
    }

    /// Scans the given categories (default: all categories enabled in settings).
    public func scan(categories: Set<CleanupCategory>? = nil, progress: ScanProgressReporter = ScanProgressReporter()) async -> ScanResult {
        let started = Date()
        let selected = scanners.filter { scanner in
            if let categories { return categories.contains(scanner.category) }
            return settings.isEnabled(scanner.category)
        }
        progress.begin(totalCategories: selected.count)
        let context = makeContext(progress: progress, now: started)
        UpkeepLog.scan.info("Scan started (\(selected.count) categories)")

        var results: [CategoryResult] = []
        var cancelled = false
        for scanner in selected {
            if Task.isCancelled {
                cancelled = true
                break
            }
            progress.beginCategory(scanner.category)
            let result = await scanner.scan(context)
            results.append(result)
            progress.finishCategory()
            UpkeepLog.scan.debug("\(scanner.category.rawValue): \(result.items.count) items, \(result.issues.count) issues")
        }
        if Task.isCancelled { cancelled = true }

        let result = ScanResult(startedAt: started, finishedAt: Date(), categories: results, wasCancelled: cancelled)
        UpkeepLog.scan.info("Scan finished: \(result.allItems.count) items, \(Formatting.bytes(result.reclaimableBytes)) reclaimable\(cancelled ? " (cancelled)" : "")")
        return result
    }

    /// The separate, informational large-file scan.
    public func scanLargeFiles(progress: ScanProgressReporter = ScanProgressReporter()) async -> CategoryResult {
        progress.begin(totalCategories: 1)
        progress.beginCategory(.largeFiles)
        let result = await LargeFilesScanner().scan(makeContext(progress: progress))
        progress.finishCategory()
        return result
    }
}
