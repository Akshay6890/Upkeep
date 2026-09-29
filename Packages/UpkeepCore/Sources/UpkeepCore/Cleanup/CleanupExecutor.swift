import Foundation

public struct CleanupOptions: Sendable {
    public var dryRun: Bool
    public var moveToTrash: Bool

    public init(dryRun: Bool, moveToTrash: Bool) {
        self.dryRun = dryRun
        self.moveToTrash = moveToTrash
    }
}

/// Cleans one item. For file-system items the sequence is:
/// 1. check the item's root is still an approved root for its rule,
/// 2. validate the path (confinement, symlinks, protected paths),
/// 3. confirm it still exists and is the same file system object as at scan time,
/// 4. re-run the rule against fresh metadata,
/// 5. remove it (or move it to the Trash) with the confined remover,
/// 6. verify it is gone and record the space actually freed.
struct CleanupExecutor: Sendable {
    let environment: ScanEnvironment
    let settings: UpkeepSettings
    let fileSystem: FileSystemService
    let validator: PathValidator
    let toolLocator: ToolLocator
    let toolRunner: ToolRunning
    let runningBundleIdentifiers: Set<String>

    private var log: UpkeepLog { .cleanup }

    func ruleContext() -> RuleContext {
        RuleContext(
            settings: settings,
            now: Date(),
            currentUserID: environment.currentUserID,
            runningBundleIdentifiers: runningBundleIdentifiers,
            homebrewInstalled: toolLocator.locate(.brew) != nil
        )
    }

    func execute(_ item: CleanupItem, options: CleanupOptions) async -> CleanupOutcome {
        let rule = RuleBook.rule(for: item.ruleID)
        guard item.isCleanable, rule.allows(item.method), rule.category == item.category else {
            return .skipped(reason: "This item can't be cleaned by Upkeep.")
        }
        switch item.method {
        case .delete, .deletePermanently:
            return executeFileSystemItem(item, rule: rule, options: options)
        case .tool(let command):
            return await executeTool(command, item: item, options: options)
        case .revealOnly:
            return .skipped(reason: "This item can't be cleaned by Upkeep.")
        }
    }

    // MARK: File system

    func executeFileSystemItem(_ item: CleanupItem, rule: CleanupRule, options: CleanupOptions) -> CleanupOutcome {
        guard rule.isFileSystemRule,
              let rootURL = item.rootURL,
              let root = environment.approvedRoot(matching: rootURL, kinds: rule.rootKinds) else {
            log.error("Refused item outside approved roots", path: item.url.path)
            return .failed(reason: FileSystemError.outsideApprovedRoot(item.url.path).description)
        }

        let validated: ValidatedPath
        do {
            validated = try validator.validate(item.url, within: root.url)
        } catch FileSystemError.notFound {
            return .skipped(reason: "It no longer exists.")
        } catch let error as FileSystemError {
            log.warning("Validation refused item: \(error)", path: item.url.path)
            return .failed(reason: error.description)
        } catch {
            return .failed(reason: "\(error)")
        }

        let info: FileInfo
        do {
            info = try fileSystem.info(at: validated.url)
        } catch FileSystemError.notFound {
            return .skipped(reason: "It no longer exists.")
        } catch {
            return .failed(reason: "\(error)")
        }
        if info.isSymlink {
            return .skipped(reason: FileSystemError.symlinkRefused(validated.path).description)
        }
        if let scanned = item.identity, scanned != info.identity {
            return .skipped(reason: "It was replaced after the scan. Scan again to review it.")
        }

        let measurement: DiskUsage? = (info.isDirectory || rule.needsMeasurement)
            ? fileSystem.measure(validated.url, options: MeasureOptions(detectSensitiveNames: rule.sensitiveHandling != .allow))
            : nil
        let childNames: [String]? = rule.needsChildNames
            ? (try? fileSystem.contentsOfDirectory(at: validated.url))?.map(\.lastPathComponent)
            : nil
        let candidate = RuleCandidate(
            url: validated.url, info: info, rootKind: root.kind,
            relativeComponents: validated.components, measurement: measurement, childNames: childNames
        )
        let verdict = rule.evaluate(candidate, context: ruleContext())
        guard case .candidate(let risk, _, _) = verdict else {
            return .skipped(reason: "It no longer matches the cleanup rule: \(verdict.explanation)")
        }
        if risk > item.risk {
            // Became riskier since the scan (e.g. the app started running): make the user look again.
            return .skipped(reason: "Its safety level changed to \(risk.shortTitle) since the scan. Scan again to review it.")
        }

        let bytesBefore = measurement?.allocatedBytes ?? info.allocatedSize
        if options.dryRun {
            return .wouldRemove(bytes: bytesBefore)
        }

        if options.moveToTrash, item.method == .delete, fileSystem.supportsTrash {
            do {
                try fileSystem.moveToTrash(validated, expectedIdentity: info.identity)
                log.info("Moved item to Trash", path: validated.path)
                return .movedToTrash(bytes: bytesBefore)
            } catch {
                log.warning("Move to Trash failed: \(error)", path: validated.path)
                return .failed(reason: "\(error)")
            }
        }

        let report: RemovalReport
        do {
            report = try fileSystem.removeItem(validated, expectedIdentity: info.identity)
        } catch FileSystemError.notFound {
            return .skipped(reason: "It no longer exists.")
        } catch let error as FileSystemError {
            log.warning("Removal failed: \(error)", path: validated.path)
            return .failed(reason: error.description)
        } catch {
            return .failed(reason: "\(error)")
        }

        switch verify(validated.url, originalIdentity: info.identity) {
        case .removed:
            log.info("Removed item (\(bytesBefore) bytes)", path: validated.path)
            return .removed(freedBytes: bytesBefore, note: nil)
        case .recreated(let current):
            return .removed(freedBytes: max(0, bytesBefore - current), note: "The app recreated it immediately.")
        case .stillPresent(let remaining) where report.itemRemoved:
            // The remover confirmed the original was unlinked, so whatever is there now
            // is new (some file systems reuse inode numbers immediately).
            return .removed(freedBytes: max(0, bytesBefore - remaining), note: "The app recreated it immediately.")
        case .stillPresent(let remaining):
            let reason = report.failures.first.map { "Some files couldn't be removed (\($0))." }
                ?? "Some files couldn't be removed."
            return .partial(freedBytes: max(0, bytesBefore - remaining), reason: reason)
        }
    }

    func verify(_ url: URL, originalIdentity: FileIdentity?) -> VerificationStatus {
        guard let info = try? fileSystem.info(at: url) else { return .removed }
        let size = info.isDirectory ? fileSystem.measure(url).allocatedBytes : info.allocatedSize
        if let originalIdentity, originalIdentity != info.identity {
            return .recreated(currentBytes: size)
        }
        return .stillPresent(remainingBytes: size)
    }

    // MARK: Tools

    func executeTool(_ command: ToolCommand, item: CleanupItem, options: CleanupOptions) async -> CleanupOutcome {
        switch command {
        case .homebrewCleanup:
            return await runHomebrewCleanup(options: options)
        case .npmCacheClean:
            return await runCacheTool(
                .npm, arguments: ["cache", "clean", "--force"], item: item,
                expectedPath: environment.npmDirectory.appendingPathComponent("_cacache"), options: options
            )
        case .yarnCacheClean:
            return await runCacheTool(
                .yarn, arguments: ["cache", "clean"], item: item,
                expectedPath: environment.caches.appendingPathComponent("Yarn"), options: options
            )
        case .pnpmStorePrune:
            return await runCacheTool(
                .pnpm, arguments: ["store", "prune"], item: item,
                expectedPath: environment.pnpmHome.appendingPathComponent("store"), options: options
            )
        case .simctlDeleteDevice(let udid):
            return await runSimulatorDelete(udid: udid, item: item, options: options)
        }
    }

    private func runHomebrewCleanup(options: CleanupOptions) async -> CleanupOutcome {
        let service = HomebrewService(locator: toolLocator, runner: toolRunner)
        guard let installation = service.detect() else {
            return .skipped(reason: "Homebrew is no longer installed.")
        }
        do {
            let before = try await service.previewCleanup(installation)
            if options.dryRun { return .wouldRemove(bytes: before.totalBytes) }
            guard before.totalBytes > 0 || !before.entries.isEmpty else {
                return .skipped(reason: "Homebrew has nothing left to clean up.")
            }
            _ = try await service.cleanup(installation)
            let after = (try? await service.previewCleanup(installation))?.totalBytes ?? 0
            log.info("brew cleanup finished")
            let note = after > 0 ? "Homebrew kept \(Formatting.bytes(after)) it still considers in use." : nil
            return .removed(freedBytes: max(0, before.totalBytes - after), note: note)
        } catch {
            log.warning("brew cleanup failed: \(error)")
            return .failed(reason: "\(error)")
        }
    }

    private func runCacheTool(
        _ tool: DeveloperTool, arguments: [String], item: CleanupItem, expectedPath: URL, options: CleanupOptions
    ) async -> CleanupOutcome {
        // The item must still describe exactly the cache this command manages.
        guard item.url.standardizedFileURL.path == expectedPath.standardizedFileURL.path else {
            return .failed(reason: "Unexpected location for \(tool.rawValue) cache.")
        }
        guard let executable = toolLocator.locate(tool) else {
            return .skipped(reason: "\(tool.rawValue) is no longer installed.")
        }
        guard fileSystem.exists(expectedPath) else {
            return .skipped(reason: "It no longer exists.")
        }
        let before = fileSystem.measure(expectedPath).allocatedBytes
        if options.dryRun { return .wouldRemove(bytes: before) }
        do {
            let output = try await toolRunner.run(
                executable, arguments: arguments,
                environment: toolLocator.toolEnvironment(for: executable), timeout: 600
            )
            guard output.succeeded else {
                return .failed(reason: HomebrewService.failureMessage("\(tool.rawValue) \(arguments.joined(separator: " "))", output))
            }
        } catch {
            return .failed(reason: "\(error)")
        }
        let after = fileSystem.exists(expectedPath) ? fileSystem.measure(expectedPath).allocatedBytes : 0
        log.info("\(tool.rawValue) cache cleanup finished")
        return .removed(freedBytes: max(0, before - after), note: nil)
    }

    private func runSimulatorDelete(udid: String, item: CleanupItem, options: CleanupOptions) async -> CleanupOutcome {
        guard SimctlParser.isValidUDID(udid) else { return .failed(reason: "Invalid simulator identifier.") }
        let service = SimulatorService(locator: toolLocator, runner: toolRunner)
        guard service.isAvailable() else { return .skipped(reason: "Xcode simulators are no longer available.") }
        do {
            let devices = try await service.listDevices()
            guard let entry = devices.first(where: { $0.device.udid == udid }) else {
                return .skipped(reason: "The simulator no longer exists.")
            }
            guard !entry.device.isAvailable else {
                return .skipped(reason: "The simulator's runtime is available again.")
            }
            let deviceDirectory = environment.simulatorDevices.appendingPathComponent(udid, isDirectory: true)
            let before = fileSystem.exists(deviceDirectory) ? fileSystem.measure(deviceDirectory).allocatedBytes : 0
            if options.dryRun { return .wouldRemove(bytes: before) }
            try await service.deleteDevice(udid: udid)
            let remaining = fileSystem.exists(deviceDirectory) ? fileSystem.measure(deviceDirectory).allocatedBytes : 0
            return .removed(freedBytes: max(0, before - remaining), note: nil)
        } catch {
            return .failed(reason: "\(error)")
        }
    }
}
