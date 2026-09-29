import Foundation

/// The single entry point the app and the CLI use:
/// `scan()`, `calculateSize()`, `preview()`, `cleanup()` and `verify()`.
public struct CleanupEngine: Sendable {
    public let environment: ScanEnvironment
    public let settings: UpkeepSettings
    public let fileSystem: FileSystemService
    public let toolRunner: ToolRunning
    public let runningBundleIdentifiers: Set<String>

    public init(
        environment: ScanEnvironment,
        settings: UpkeepSettings,
        fileSystem: FileSystemService = LocalFileSystem(),
        toolRunner: ToolRunning = ProcessToolRunner(),
        runningBundleIdentifiers: Set<String> = []
    ) {
        self.environment = environment
        self.settings = settings.normalized()
        self.fileSystem = fileSystem
        self.toolRunner = toolRunner
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }

    public var coordinator: ScanCoordinator {
        ScanCoordinator(
            environment: environment, settings: settings, fileSystem: fileSystem,
            toolRunner: toolRunner, runningBundleIdentifiers: runningBundleIdentifiers
        )
    }

    private var executor: CleanupExecutor {
        CleanupExecutor(
            environment: environment,
            settings: settings,
            fileSystem: fileSystem,
            validator: PathValidator(
                fileSystem: fileSystem,
                protectedPaths: ProtectedPaths(homeDirectory: environment.homeDirectory, fileSystem: fileSystem)
            ),
            toolLocator: ToolLocator(environment: environment, fileSystem: fileSystem),
            toolRunner: toolRunner,
            runningBundleIdentifiers: runningBundleIdentifiers
        )
    }

    // MARK: Scan

    public func scan(categories: Set<CleanupCategory>? = nil, progress: ScanProgressReporter = ScanProgressReporter()) async -> ScanResult {
        await coordinator.scan(categories: categories, progress: progress)
    }

    public func scanLargeFiles(progress: ScanProgressReporter = ScanProgressReporter()) async -> CategoryResult {
        await coordinator.scanLargeFiles(progress: progress)
    }

    // MARK: Size

    public func calculateSize(of url: URL) -> DiskUsage {
        fileSystem.measure(url)
    }

    // MARK: Preview

    public func preview(_ items: [CleanupItem]) -> CleanupPlan {
        CleanupPlan(selection: items)
    }

    // MARK: Cleanup

    /// Processes every item in the plan. A failure on one item never stops the others.
    public func cleanup(
        _ plan: CleanupPlan,
        options: CleanupOptions,
        progress: (@Sendable (CleanupProgress) -> Void)? = nil
    ) async -> CleanupReport {
        let started = Date()
        let executor = self.executor
        var results: [CleanupItemResult] = []
        var state = CleanupProgress(completed: 0, total: plan.items.count, currentItemName: nil, currentOperation: nil, bytesReclaimed: 0)
        UpkeepLog.cleanup.info("Cleanup started: \(plan.items.count) items\(options.dryRun ? " (dry run)" : "")")

        // File-system items first, then tool commands.
        let ordered = plan.items.filter { !Self.isTool($0) } + plan.items.filter(Self.isTool)
        for item in ordered {
            if Task.isCancelled {
                results.append(CleanupItemResult(item: item, outcome: .skipped(reason: "Cleanup was cancelled.")))
                continue
            }
            state.currentItemName = item.name
            state.currentOperation = options.dryRun ? "Checking \(item.name)" : Self.operationDescription(for: item, moveToTrash: options.moveToTrash)
            progress?(state)

            let outcome = await executor.execute(item, options: options)
            results.append(CleanupItemResult(item: item, outcome: outcome))
            state.completed += 1
            state.bytesReclaimed += outcome.freedBytes
            progress?(state)
        }

        state.currentItemName = nil
        state.currentOperation = nil
        progress?(state)
        let report = CleanupReport(startedAt: started, finishedAt: Date(), dryRun: options.dryRun, results: results)
        UpkeepLog.cleanup.info("Cleanup finished: \(report.succeeded.count) succeeded, \(report.skipped.count) skipped, \(report.failed.count) failed, \(Formatting.bytes(report.reclaimedBytes)) reclaimed")
        return report
    }

    // MARK: Verify

    public func verify(_ item: CleanupItem) -> VerificationStatus {
        executor.verify(item.url, originalIdentity: item.identity)
    }

    private static func isTool(_ item: CleanupItem) -> Bool {
        if case .tool = item.method { return true }
        return false
    }

    private static func operationDescription(for item: CleanupItem, moveToTrash: Bool) -> String {
        switch item.method {
        case .delete: return moveToTrash ? "Moving \(item.name) to the Trash" : "Removing \(item.name)"
        case .deletePermanently: return "Deleting \(item.name) permanently"
        case .tool(let command): return "Running \(command.displayCommand)"
        case .revealOnly: return item.name
        }
    }
}
