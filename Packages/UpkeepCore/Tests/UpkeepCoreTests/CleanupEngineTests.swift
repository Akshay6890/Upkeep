import XCTest
@testable import UpkeepCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class CleanupEngineTests: XCTestCase {
    var fixture: Fixture!

    override func setUpWithError() throws {
        fixture = try Fixture()
    }

    override func tearDown() {
        fixture = nil
    }

    func engine(fileSystem: FileSystemService = LocalFileSystem(), runner: ToolRunning = MockToolRunner(), settings: UpkeepSettings = UpkeepSettings(), environment: ScanEnvironment? = nil) -> CleanupEngine {
        CleanupEngine(environment: environment ?? fixture.environment, settings: settings, fileSystem: fileSystem, toolRunner: runner)
    }

    /// Builds a small but realistic fixture and returns the scan result.
    func scanStandardFixture(_ engine: CleanupEngine) async throws -> ScanResult {
        try fixture.file("Library/Caches/com.example.App/blob", bytes: 20_000)
        try fixture.file("Library/Caches/com.example.Other/blob", bytes: 10_000)
        try fixture.file("Library/Logs/App/old.log", bytes: 3_000, ageDays: 40)
        try fixture.file("Library/Logs/App/new.log", bytes: 3_000)
        try fixture.file(".Trash/deleted.txt", bytes: 1_000)
        try fixture.file("keep/me.txt", in: fixture.outside)
        return await engine.scan()
    }

    // MARK: End to end

    func testCleanupRemovesSelectedItemsAndVerifies() async throws {
        let engine = engine()
        let scan = try await scanStandardFixture(engine)
        let selection = scan.allItems.filter { $0.risk == .safe }
        XCTAssertEqual(Set(selection.map(\.name)), ["com.example.App", "com.example.Other", "App › old.log"])

        let plan = engine.preview(selection)
        XCTAssertEqual(plan.items.count, 3)
        XCTAssertEqual(plan.totalBytes, selection.reduce(0) { $0 + $1.size })
        XCTAssertEqual(plan.groups.map(\.category), [.applicationCaches, .logs])

        let recorder = ProgressRecorder()
        let report = await engine.cleanup(plan, options: CleanupOptions(dryRun: false, moveToTrash: false)) { recorder.append($0) }
        XCTAssertEqual(report.succeeded.count, 3)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(report.reclaimedBytes, plan.totalBytes)
        XCTAssertEqual(recorder.last?.completed, 3)

        for item in selection {
            XCTAssertFalse(fixture.exists(item.url), item.name)
            XCTAssertEqual(engine.verify(item), .removed)
        }
        // Everything else is untouched.
        XCTAssertTrue(fixture.exists(fixture.home.appendingPathComponent("Library/Logs/App/new.log")))
        XCTAssertTrue(fixture.exists(fixture.home.appendingPathComponent(".Trash/deleted.txt")))
        XCTAssertTrue(fixture.exists(fixture.home.appendingPathComponent("Library/Caches")))
        XCTAssertTrue(fixture.exists(fixture.outside.appendingPathComponent("keep/me.txt")))
    }

    func testDryRunRemovesNothing() async throws {
        let engine = engine()
        let scan = try await scanStandardFixture(engine)
        let plan = engine.preview(scan.allItems)
        let report = await engine.cleanup(plan, options: CleanupOptions(dryRun: true, moveToTrash: false))
        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.reclaimedBytes, 0)
        XCTAssertEqual(report.wouldReclaimBytes, plan.totalBytes)
        for item in scan.allItems { XCTAssertTrue(fixture.exists(item.url), item.name) }
    }

    func testTrashIsDeletedPermanentlyEvenWhenMoveToTrashIsOn() async throws {
        let fs = FaultInjectingFileSystem()
        fs.trashSupported = true
        let engine = engine(fileSystem: fs)
        let scan = try await scanStandardFixture(engine)
        let trashItem = try XCTUnwrap(scan.result(for: .trash)?.items.first)
        let cache = try XCTUnwrap(scan.result(for: .applicationCaches)?.items.first)
        let report = await engine.cleanup(engine.preview([trashItem, cache]), options: CleanupOptions(dryRun: false, moveToTrash: true))
        XCTAssertEqual(report.results.first { $0.item.id == trashItem.id }?.outcome.freedBytes, trashItem.size)
        guard case .movedToTrash = report.results.first(where: { $0.item.id == cache.id })?.outcome else {
            return XCTFail("cache should be moved to Trash")
        }
        XCTAssertEqual(fs.trashed.count, 1)
        XCTAssertEqual(report.movedToTrashBytes, cache.size)
    }

    // MARK: Race conditions

    func testItemDeletedAfterScanIsSkipped() async throws {
        let engine = engine()
        let scan = try await scanStandardFixture(engine)
        let item = try XCTUnwrap(scan.result(for: .applicationCaches)?.items.first)
        try FileManager.default.removeItem(at: item.url)
        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .skipped(let reason) = report.results.first?.outcome else { return XCTFail() }
        XCTAssertTrue(reason.contains("no longer exists"))
    }

    func testItemReplacedAfterScanIsSkipped() async throws {
        let engine = engine()
        let scan = try await scanStandardFixture(engine)
        let item = try XCTUnwrap(scan.result(for: .applicationCaches)?.items.first { $0.name == "com.example.App" })
        let replacement = try fixture.dir("Library/Caches/com.example.App.new")
        try fixture.file("Library/Caches/com.example.App.new/important")
        try FileManager.default.removeItem(at: item.url)
        XCTAssertEqual(rename(replacement.path, item.url.path), 0)
        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .skipped(let reason) = report.results.first?.outcome else { return XCTFail() }
        XCTAssertTrue(reason.contains("replaced"))
        XCTAssertTrue(fixture.exists(item.url.appendingPathComponent("important")))
    }

    func testItemSwappedForSymlinkIsNotFollowed() async throws {
        let engine = engine()
        let scan = try await scanStandardFixture(engine)
        let item = try XCTUnwrap(scan.result(for: .applicationCaches)?.items.first)
        let victim = fixture.outside.appendingPathComponent("keep/me.txt")
        try FileManager.default.removeItem(at: item.url)
        _ = try fixture.symlink("keep-link", to: fixture.outside.appendingPathComponent("keep"), in: item.url.deletingLastPathComponent())
        XCTAssertEqual(rename(item.url.deletingLastPathComponent().appendingPathComponent("keep-link").path, item.url.path), 0)
        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        XCTAssertFalse(report.results.first?.outcome.isSuccess ?? true)
        XCTAssertTrue(fixture.exists(victim))
    }

    func testItemThatNoLongerMatchesRuleIsSkipped() async throws {
        let engine = engine()
        let scan = try await scanStandardFixture(engine)
        let log = try XCTUnwrap(scan.result(for: .logs)?.items.first)
        // The app wrote to the log after the scan, so it is no longer old.
        let handle = try FileHandle(forWritingTo: log.url)
        handle.seekToEndOfFile()
        handle.write(Data("new line\n".utf8))
        try handle.close()
        let report = await engine.cleanup(engine.preview([log]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .skipped(let reason) = report.results.first?.outcome else { return XCTFail() }
        XCTAssertTrue(reason.contains("no longer matches"))
        XCTAssertTrue(fixture.exists(log.url))
    }

    func testItemThatBecameRiskierIsSkipped() async throws {
        let scanEngine = engine()
        let scan = try await scanStandardFixture(scanEngine)
        let item = try XCTUnwrap(scan.result(for: .applicationCaches)?.items.first { $0.name == "com.example.App" })
        XCTAssertEqual(item.risk, .safe)
        // The app was launched between scan and cleanup.
        let cleanEngine = CleanupEngine(environment: fixture.environment, settings: UpkeepSettings(), toolRunner: MockToolRunner(), runningBundleIdentifiers: ["com.example.App"])
        let report = await cleanEngine.cleanup(cleanEngine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .skipped(let reason) = report.results.first?.outcome else { return XCTFail() }
        XCTAssertTrue(reason.contains("safety level changed"))
        XCTAssertTrue(fixture.exists(item.url))
    }

    func testCacheRecreatedByAppIsReported() async throws {
        let fs = FaultInjectingFileSystem()
        fs.afterRemoval = { target in
            try? FileManager.default.createDirectory(atPath: target.path, withIntermediateDirectories: false)
        }
        let engine = engine(fileSystem: fs)
        let scan = try await scanStandardFixture(engine)
        let item = try XCTUnwrap(scan.result(for: .applicationCaches)?.items.first)
        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .removed(_, let note) = report.results.first?.outcome else { return XCTFail() }
        XCTAssertEqual(note, "The app recreated it immediately.")
    }

    // MARK: Failures are isolated

    func testOneFailureDoesNotStopTheRest() async throws {
        let fs = FaultInjectingFileSystem()
        let engine = engine(fileSystem: fs)
        let scan = try await scanStandardFixture(engine)
        let caches = try XCTUnwrap(scan.result(for: .applicationCaches)?.items)
        let failing = try XCTUnwrap(caches.first { $0.name == "com.example.App" })
        fs.failRemovalWith[try LocalFileSystem().canonicalPath(failing.url)] = .permissionDenied(failing.url.path)
        let report = await engine.cleanup(engine.preview(caches), options: CleanupOptions(dryRun: false, moveToTrash: false))
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(report.succeeded.count, 1)
        guard case .failed(let reason) = report.failed.first?.outcome else { return XCTFail() }
        XCTAssertEqual(reason, "macOS denied access.")
        XCTAssertTrue(fixture.exists(failing.url))
    }

    func testPartialRemovalIsReported() async throws {
        try XCTSkipIf(Fixture.isRoot, "Permission checks don't apply to root.")
        let engine = engine()
        try fixture.file("Library/Caches/com.example.App/free.bin", bytes: 5_000)
        let locked = try fixture.dir("Library/Caches/com.example.App/locked")
        try fixture.file("Library/Caches/com.example.App/locked/stuck.bin", bytes: 5_000)
        let scan = await engine.scan(categories: [.applicationCaches])
        let item = try XCTUnwrap(scan.allItems.first)
        chmod(locked.path, 0o500)
        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .partial = report.results.first?.outcome else { return XCTFail("\(String(describing: report.results.first?.outcome))") }
    }

    // MARK: Crafted / invalid items

    func testItemOutsideApprovedRootsIsRefused() async throws {
        let victim = try fixture.file("keep/me.txt", in: fixture.outside)
        let info = try LocalFileSystem().info(at: victim)
        let forged = CleanupItem(
            name: "me.txt", url: victim, category: .applicationCaches, risk: .safe, ruleID: .applicationCache,
            reason: "", source: "", rootURL: fixture.outside, method: .delete, size: 1, fileCount: 1,
            modifiedDate: nil, identity: info.identity
        )
        let engine = engine()
        let report = await engine.cleanup(engine.preview([forged]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .failed = report.results.first?.outcome else { return XCTFail() }
        XCTAssertTrue(fixture.exists(victim))
    }

    func testTraversalPathIsRefused() async throws {
        try fixture.dir("Library/Caches")
        let victim = try fixture.file("keep/me.txt", in: fixture.outside)
        let traversal = URL(fileURLWithPath: fixture.environment.caches.path + "/../../../outside/keep")
        let forged = CleanupItem(
            name: "keep", url: traversal, category: .applicationCaches, risk: .safe, ruleID: .applicationCache,
            reason: "", source: "", rootURL: fixture.environment.caches, method: .delete, size: 1, fileCount: 1,
            modifiedDate: nil, identity: nil
        )
        let engine = engine()
        let report = await engine.cleanup(engine.preview([forged]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .failed(let reason) = report.results.first?.outcome else { return XCTFail() }
        XCTAssertEqual(reason, FileSystemError.invalidPath("").description)
        XCTAssertTrue(fixture.exists(victim))
    }

    func testItemWithMismatchedRuleIsExcludedFromPlan() throws {
        let url = try fixture.dir("Library/Caches/com.example.App")
        let wrongMethod = CleanupItem(
            name: "x", url: url, category: .applicationCaches, risk: .safe, ruleID: .applicationCache,
            reason: "", source: "", rootURL: fixture.environment.caches, method: .tool(.homebrewCleanup),
            size: 1, fileCount: 1, modifiedDate: nil, identity: nil
        )
        let protected = CleanupItem(
            name: "y", url: url, category: .applicationCaches, risk: .protected, ruleID: .applicationCache,
            reason: "", source: "", rootURL: fixture.environment.caches, method: .revealOnly,
            size: 1, fileCount: 1, modifiedDate: nil, identity: nil, idSuffix: "p"
        )
        let wrongCategory = CleanupItem(
            name: "z", url: url, category: .trash, risk: .safe, ruleID: .applicationCache,
            reason: "", source: "", rootURL: fixture.environment.caches, method: .delete,
            size: 1, fileCount: 1, modifiedDate: nil, identity: nil, idSuffix: "c"
        )
        let plan = CleanupPlan(selection: [wrongMethod, protected, wrongCategory])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.excluded.count, 3)
    }

    func testLargeFilesCanNeverBeCleaned() async throws {
        let file = try fixture.file("Movies/big.mov", bytes: 1_000)
        let info = try LocalFileSystem().info(at: file)
        let item = CleanupItem(
            name: "big.mov", url: file, category: .largeFiles, risk: .review, ruleID: .largeFile,
            reason: "", source: "", rootURL: nil, method: .revealOnly, size: 1_000, fileCount: 1,
            modifiedDate: nil, identity: info.identity
        )
        XCTAssertTrue(CleanupPlan(selection: [item]).isEmpty)
        let engine = engine()
        let report = await engine.cleanup(CleanupPlan(selection: [item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        XCTAssertTrue(report.results.isEmpty)
        XCTAssertTrue(fixture.exists(file))
    }

    // MARK: Tools

    func testNpmCacheCleanUsesTheToolAndMeasuresFreedSpace() async throws {
        try fixture.fakeTool("npm")
        let cache = try fixture.dir(".npm/_cacache")
        try fixture.file(".npm/_cacache/content/blob", bytes: 50_000)
        let runner = MockToolRunner { executable, args in
            XCTAssertEqual(executable.lastPathComponent, "npm")
            XCTAssertEqual(args, ["cache", "clean", "--force"])
            try FileManager.default.removeItem(at: cache)
            return ToolOutput(exitCode: 0, standardOutput: "", standardError: "")
        }
        let engine = engine(runner: runner)
        let scan = await engine.scan(categories: [.nodePackageManagers])
        let item = try XCTUnwrap(scan.allItems.first { $0.name == "_cacache" })
        XCTAssertEqual(item.method, .tool(.npmCacheClean))

        let dry = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: true, moveToTrash: false))
        XCTAssertTrue(runner.recordedArguments.isEmpty, "Dry run must not run the tool")
        XCTAssertEqual(dry.wouldReclaimBytes, item.size)

        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        XCTAssertEqual(report.reclaimedBytes, item.size)
        XCTAssertEqual(runner.recordedArguments.count, 1)
    }

    func testToolFailureIsReported() async throws {
        try fixture.fakeTool("npm")
        try fixture.file(".npm/_cacache/content/blob", bytes: 5_000)
        let runner = MockToolRunner { _, _ in ToolOutput(exitCode: 1, standardOutput: "", standardError: "npm ERR! nope") }
        let engine = engine(runner: runner)
        let scan = await engine.scan(categories: [.nodePackageManagers])
        let item = try XCTUnwrap(scan.allItems.first { $0.name == "_cacache" })
        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .failed(let reason) = report.results.first?.outcome else { return XCTFail() }
        XCTAssertTrue(reason.contains("npm ERR! nope"))
    }

    func testHomebrewCleanupReportsDifferenceBetweenDryRuns() async throws {
        try fixture.fakeTool("brew")
        let state = CallCounter()
        let runner = MockToolRunner { _, args in
            switch args {
            case ["--cache"]:
                return ToolOutput(exitCode: 0, standardOutput: "/c\n", standardError: "")
            case ["cleanup", "--dry-run"]:
                let text = state.value == 0
                    ? "Would remove: /c/a (4MB)\n==> This operation would free approximately 4MB of disk space."
                    : ""
                return ToolOutput(exitCode: 0, standardOutput: text, standardError: "")
            case ["cleanup"]:
                state.increment()
                return ToolOutput(exitCode: 0, standardOutput: "Removing: /c/a", standardError: "")
            default:
                return ToolOutput(exitCode: 1, standardOutput: "", standardError: "unexpected")
            }
        }
        let engine = engine(runner: runner)
        let scan = await engine.scan(categories: [.homebrew])
        let item = try XCTUnwrap(scan.allItems.first)
        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        XCTAssertEqual(report.reclaimedBytes, 4 * 1_048_576)
        XCTAssertEqual(state.value, 1)
    }

    func testSimulatorDeleteRevalidatesAvailability() async throws {
        try fixture.dir("Applications/Xcode.app", in: fixture.root)
        try fixture.fakeTool("xcrun")
        let udid = "11111111-2222-3333-4444-555555555555"
        try fixture.file("Library/Developer/CoreSimulator/Devices/\(udid)/data/x", bytes: 1_000)
        let available = Flag()
        let runner = MockToolRunner { _, args in
            if args.starts(with: ["simctl", "list"]) {
                let json = "{\"devices\": {\"com.apple.CoreSimulator.SimRuntime.iOS-16-4\": [{\"udid\": \"\(udid)\", \"name\": \"iPhone\", \"isAvailable\": \(available.value)}]}}"
                return ToolOutput(exitCode: 0, standardOutput: json, standardError: "")
            }
            XCTFail("simctl delete must not run for an available simulator")
            return ToolOutput(exitCode: 0, standardOutput: "", standardError: "")
        }
        let engine = engine(runner: runner)
        let scan = await engine.scan(categories: [.xcode])
        let item = try XCTUnwrap(scan.allItems.first { $0.ruleID == .unavailableSimulator })
        available.set()
        let report = await engine.cleanup(engine.preview([item]), options: CleanupOptions(dryRun: false, moveToTrash: false))
        guard case .skipped = report.results.first?.outcome else { return XCTFail() }
    }

    func testPlanWarnings() async throws {
        let engine = engine()
        let scan = try await scanStandardFixture(engine)
        let plan = engine.preview(scan.allItems)
        XCTAssertTrue(plan.warnings.contains { $0.contains("permanently") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("Review") })
        XCTAssertGreaterThan(plan.permanentBytes, 0)
    }

    func testCalculateSize() throws {
        let dir = try fixture.dir("sized")
        try fixture.file("sized/a", bytes: 1_234)
        XCTAssertEqual(engine().calculateSize(of: dir).logicalBytes, 1_234)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CleanupProgress] = []
    func append(_ value: CleanupProgress) { lock.lock(); values.append(value); lock.unlock() }
    var last: CleanupProgress? { lock.lock(); defer { lock.unlock() }; return values.last }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
