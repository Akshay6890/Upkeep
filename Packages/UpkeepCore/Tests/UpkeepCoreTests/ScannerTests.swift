import XCTest
@testable import UpkeepCore

final class ScannerTests: XCTestCase {
    var fixture: Fixture!

    override func setUpWithError() throws {
        fixture = try Fixture()
    }

    override func tearDown() {
        fixture = nil
    }

    func testCacheScannerFindsAppCachesAndSkipsSymlinks() async throws {
        try fixture.file("Library/Caches/com.example.App/data.bin", bytes: 10_000)
        try fixture.file("Library/Caches/com.example.Other/data.bin", bytes: 5_000)
        try fixture.file("Library/Caches/Unknown/data.bin")
        try fixture.file("Library/Caches/com.apple.bird/data.bin")
        try fixture.file("big", in: fixture.outside, bytes: 100_000)
        _ = try fixture.symlink("Library/Caches/com.example.Link", to: fixture.outside)
        try fixture.dir("Library/Caches/com.example.Empty")

        let result = await CacheScanner().scan(scanContext(fixture))
        XCTAssertEqual(result.items.map(\.name).sorted(), ["com.example.App", "com.example.Other"])
        XCTAssertTrue(result.items.allSatisfy { $0.risk == .safe && $0.method == .delete })
        XCTAssertEqual(result.items.first?.name, "com.example.App", "sorted by size")

        var settings = UpkeepSettings()
        settings.showProtectedItems = true
        let withProtected = await CacheScanner().scan(scanContext(fixture, settings: settings))
        let protected = withProtected.items.filter { $0.risk == .protected }
        XCTAssertEqual(Set(protected.map(\.name)), ["Unknown", "com.apple.bird"])
        XCTAssertTrue(protected.allSatisfy { !$0.isCleanable })
        XCTAssertFalse(withProtected.items.contains { $0.name == "com.example.Link" })
    }

    func testLogsScannerHonoursAgeAndSkipsDiagnosticReports() async throws {
        try fixture.file("Library/Logs/App/old.log", ageDays: 30)
        try fixture.file("Library/Logs/App/new.log", ageDays: 1)
        try fixture.file("Library/Logs/DiagnosticReports/App-2020-01-01-000000.ips", ageDays: 90)
        let result = await LogsScanner().scan(scanContext(fixture))
        XCTAssertEqual(result.items.map(\.url.lastPathComponent), ["old.log"])
        XCTAssertEqual(result.items.first?.name, "App › old.log")
    }

    func testCrashReportsScanner() async throws {
        try fixture.file("Library/Logs/DiagnosticReports/Safari-2020-01-01-000000.ips", ageDays: 90)
        try fixture.file("Library/Logs/DiagnosticReports/Retired/Mail-2020-01-01-000000.crash", ageDays: 90)
        try fixture.file("Library/Logs/DiagnosticReports/Safari-2099-01-01-000000.ips", ageDays: 1)
        let result = await CrashReportsScanner().scan(scanContext(fixture))
        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.contains { $0.notes.contains("Application: Safari") })
        XCTAssertTrue(result.items.contains { $0.notes.contains("Application: Mail") })
    }

    func testTrashScannerListsTopLevelItemsAsPermanentReview() async throws {
        try fixture.file(".Trash/photo.jpg", bytes: 2_000)
        try fixture.file(".Trash/Old Folder/a.txt")
        try fixture.dir(".Trash/Empty Folder")
        try fixture.file(".Trash/.DS_Store")
        let result = await TrashScanner().scan(scanContext(fixture))
        XCTAssertEqual(Set(result.items.map(\.name)), ["photo.jpg", "Old Folder", "Empty Folder"])
        XCTAssertTrue(result.items.allSatisfy { $0.risk == .review && $0.isPermanent })
    }

    func testTemporaryScannerOnlyReturnsStaleItems() async throws {
        let stale = try fixture.dir("stale-dir", in: fixture.tmp)
        try fixture.file("stale-dir/x", in: fixture.tmp, ageDays: 10)
        try fixture.setAge(stale, days: 10)
        try fixture.file("stale.tmp", in: fixture.tmp, ageDays: 10)
        try fixture.file("fresh.tmp", in: fixture.tmp)
        let result = await TemporaryFilesScanner().scan(scanContext(fixture))
        XCTAssertEqual(Set(result.items.map(\.name)), ["stale-dir", "stale.tmp"])
    }

    func testXcodeDetection() throws {
        let fs = LocalFileSystem()
        XCTAssertFalse(XcodeScanner.isDeveloperToolingPresent(fixture.environment, fileSystem: fs))
        try fixture.dir("Library/Developer/Xcode")
        XCTAssertTrue(XcodeScanner.isDeveloperToolingPresent(fixture.environment, fileSystem: fs))
    }

    func testXcodeScannerUnavailableWithoutXcode() async {
        let result = await XcodeScanner().scan(scanContext(fixture))
        XCTAssertFalse(result.isAvailable)
    }

    func testXcodeScannerClassifiesItems() async throws {
        try fixture.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 1_000)
        try fixture.file("Library/Developer/Xcode/Archives/2024-01-01/App.xcarchive/Info.plist")
        try fixture.file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A)/Symbols/x")
        try fixture.file("Library/Developer/CoreSimulator/Caches/dyld/x")
        let result = await XcodeScanner().scan(scanContext(fixture))
        XCTAssertTrue(result.isAvailable)
        let byRule = Dictionary(grouping: result.items, by: \.ruleID)
        XCTAssertEqual(byRule[.xcodeDerivedData]?.first?.risk, .safe)
        XCTAssertEqual(byRule[.xcodeArchive]?.first?.risk, .review)
        XCTAssertEqual(byRule[.xcodeDeviceSupport]?.first?.risk, .review)
        XCTAssertEqual(byRule[.simulatorCaches]?.first?.risk, .review)
    }

    func testXcodeScannerListsUnavailableSimulatorsViaSimctl() async throws {
        try fixture.dir("Applications/Xcode.app", in: fixture.root)
        try fixture.fakeTool("xcrun")
        let udid = "11111111-2222-3333-4444-555555555555"
        try fixture.file("Library/Developer/CoreSimulator/Devices/\(udid)/data/file", bytes: 3_000)
        let json = """
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
          {"udid": "\(udid)", "name": "iPhone 14", "isAvailable": false, "state": "Shutdown"},
          {"udid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "name": "iPhone 15", "isAvailable": true, "state": "Shutdown"}
        ]}}
        """
        let runner = MockToolRunner { _, args in
            XCTAssertEqual(args, ["simctl", "list", "devices", "--json"])
            return ToolOutput(exitCode: 0, standardOutput: json, standardError: "")
        }
        let result = await XcodeScanner().scan(scanContext(fixture, runner: runner))
        let sims = result.items.filter { $0.ruleID == .unavailableSimulator }
        XCTAssertEqual(sims.count, 1)
        XCTAssertEqual(sims.first?.method, .tool(.simctlDeleteDevice(udid: udid)))
        XCTAssertEqual(sims.first?.risk, .review)
        XCTAssertGreaterThan(sims.first?.size ?? 0, 0)
    }

    func testMissingSimctlIsSkippedQuietlyAndUsesXcodeDeveloperDir() async throws {
        try fixture.dir("Applications/Xcode.app/Contents/Developer", in: fixture.root)
        try fixture.fakeTool("xcrun")
        try fixture.dir("Library/Developer/CoreSimulator/Devices")
        let seenDeveloperDir = Flag()
        let runner = EnvironmentRecordingRunner { environment in
            if environment["DEVELOPER_DIR"]?.hasSuffix("Xcode.app/Contents/Developer") == true { seenDeveloperDir.set() }
            return ToolOutput(exitCode: 72, standardOutput: "", standardError: "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH")
        }
        let result = await XcodeScanner().scan(scanContext(fixture, runner: runner))
        XCTAssertTrue(result.isAvailable)
        XCTAssertTrue(result.issues.isEmpty, "A missing simctl is not the user's problem")
        XCTAssertTrue(seenDeveloperDir.value)
    }

    func testHomebrewDetection() throws {
        let locator = ToolLocator(environment: fixture.environment, fileSystem: LocalFileSystem())
        XCTAssertNil(HomebrewService(locator: locator, runner: MockToolRunner()).detect())
        let brew = try fixture.fakeTool("brew")
        XCTAssertEqual(HomebrewService(locator: locator, runner: MockToolRunner()).detect()?.executable, brew)
    }

    func testUntrustedToolIsIgnored() throws {
        let brew = try fixture.fakeTool("brew")
        chmod(brew.path, 0o777) // world-writable: anyone could replace it
        let locator = ToolLocator(environment: fixture.environment, fileSystem: LocalFileSystem())
        XCTAssertNil(locator.locate(.brew))
    }

    func testHomebrewScannerHiddenWhenNotInstalled() async {
        let result = await HomebrewScanner().scan(scanContext(fixture))
        XCTAssertFalse(result.isAvailable)
    }

    func testHomebrewScannerUsesDryRun() async throws {
        try fixture.fakeTool("brew")
        let runner = MockToolRunner { _, args in
            switch args {
            case ["--cache"]:
                return ToolOutput(exitCode: 0, standardOutput: "/cache/Homebrew\n", standardError: "")
            case ["cleanup", "--dry-run"]:
                return ToolOutput(exitCode: 0, standardOutput: """
                Would remove: /cache/Homebrew/downloads/a.tar.gz (1MB)
                Would remove: /opt/homebrew/Cellar/x/1.0 (10 files, 2MB)
                ==> This operation would free approximately 3MB of disk space.
                """, standardError: "")
            default:
                XCTFail("unexpected brew \(args)")
                return ToolOutput(exitCode: 1, standardOutput: "", standardError: "")
            }
        }
        let result = await HomebrewScanner().scan(scanContext(fixture, runner: runner))
        XCTAssertEqual(result.items.count, 1)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.size, 3 * 1_048_576)
        XCTAssertEqual(item.method, .tool(.homebrewCleanup))
        XCTAssertTrue(item.notes.contains { $0.hasPrefix("Cached downloads") })
        XCTAssertTrue(item.notes.contains { $0.hasPrefix("Old package versions") })
        XCTAssertFalse(runner.recordedArguments.contains(["cleanup"]), "Scanning must never run a real cleanup")
    }

    func testHomebrewWithNothingToFreeShowsNoItem() async throws {
        try fixture.fakeTool("brew")
        let runner = MockToolRunner { _, args in
            if args == ["--cache"] { return ToolOutput(exitCode: 0, standardOutput: "/cache\n", standardError: "") }
            // Entries without a size (e.g. broken symlinks) free nothing.
            return ToolOutput(exitCode: 0, standardOutput: "Would remove: /opt/homebrew/lib/broken (symlink)\n", standardError: "")
        }
        let result = await HomebrewScanner().scan(scanContext(fixture, runner: runner))
        XCTAssertTrue(result.isAvailable)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testHomebrewFailureBecomesIssue() async throws {
        try fixture.fakeTool("brew")
        let runner = MockToolRunner { _, _ in ToolOutput(exitCode: 1, standardOutput: "", standardError: "Error: boom") }
        let result = await HomebrewScanner().scan(scanContext(fixture, runner: runner))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.issues.first?.kind, .toolFailed)
    }

    func testNodeScannerPrefersToolWhenInstalled() async throws {
        try fixture.file(".npm/_cacache/index", bytes: 1_000)
        try fixture.file(".npm/_logs/debug.log")
        try fixture.file(".npm/config-ish")
        try fixture.file("Library/Caches/Yarn/v6/pkg", bytes: 500)
        try fixture.file("Library/pnpm/store/v3/files/x")

        let without = await NodePackageManagerScanner().scan(scanContext(fixture))
        let npmWithout = without.items.first { $0.name == "_cacache" }
        XCTAssertEqual(npmWithout?.method, .delete)
        XCTAssertEqual(without.items.first { $0.name == "pnpm store" }?.method, .revealOnly)

        try fixture.fakeTool("npm")
        try fixture.fakeTool("yarn")
        try fixture.fakeTool("pnpm")
        let with = await NodePackageManagerScanner().scan(scanContext(fixture))
        XCTAssertEqual(with.items.first { $0.name == "_cacache" }?.method, .tool(.npmCacheClean))
        XCTAssertEqual(with.items.first { $0.name == "_logs" }?.method, .delete)
        XCTAssertEqual(with.items.first { $0.name == "Yarn cache" }?.method, .tool(.yarnCacheClean))
        XCTAssertEqual(with.items.first { $0.name == "pnpm store" }?.method, .tool(.pnpmStorePrune))
        XCTAssertEqual(with.items.first { $0.name == "pnpm store" }?.risk, .review)
        XCTAssertFalse(with.items.contains { $0.name == "config-ish" })
    }

    func testPythonScannerOnlyUsesApprovedFoldersAndSkipsHiddenAndNodeModules() async throws {
        let project = try fixture.dir("projects/app", in: fixture.root)
        try fixture.file("projects/app/pkg/__pycache__/a.cpython-312.pyc", in: fixture.root)
        try fixture.file("projects/app/.venv/lib/__pycache__/b.pyc", in: fixture.root)
        try fixture.file("projects/app/node_modules/x/__pycache__/c.pyc", in: fixture.root)
        try fixture.file("projects/app/mixed/__pycache__/d.pyc", in: fixture.root)
        try fixture.file("projects/app/mixed/__pycache__/keep.py", in: fixture.root)
        try fixture.file("projects/other/__pycache__/e.pyc", in: fixture.root)

        var env = fixture.environment
        env.developerFolders = [project]
        let result = await PythonCacheScanner().scan(scanContext(fixture, environment: env))
        XCTAssertEqual(result.items.map(\.name), ["pkg/__pycache__"])
    }

    func testPythonScannerUnavailableWithoutFoldersOrPip() async {
        let result = await PythonCacheScanner().scan(scanContext(fixture))
        XCTAssertFalse(result.isAvailable)
    }

    func testLargeFilesScannerIsInformationalOnly() async throws {
        var settings = UpkeepSettings()
        settings.largeFileThresholdBytes = 64 * 1024
        try fixture.file("Movies/big.mov", bytes: 200 * 1024)
        try fixture.file("Documents/small.txt", bytes: 100)
        try fixture.file("Library/Caches/huge.bin", bytes: 200 * 1024)
        try fixture.file(".Trash/huge.bin", bytes: 200 * 1024)
        let result = await LargeFilesScanner().scan(scanContext(fixture, settings: settings))
        XCTAssertEqual(result.items.map(\.name), ["big.mov"])
        XCTAssertEqual(result.items.first?.method, .revealOnly)
        XCTAssertFalse(result.items.first?.isCleanable ?? true)
    }

    func testCoordinatorRespectsCategorySettingsAndReportsProgress() async throws {
        try fixture.file("Library/Caches/com.example.App/a", bytes: 1_000)
        try fixture.file("Library/Logs/x.log", ageDays: 100)
        var settings = UpkeepSettings()
        settings.includeLogs = false
        let progress = ScanProgressReporter()
        let coordinator = ScanCoordinator(environment: fixture.environment, settings: settings, toolRunner: MockToolRunner())
        let result = await coordinator.scan(progress: progress)
        XCTAssertNil(result.result(for: .logs))
        XCTAssertNil(result.result(for: .crashReports))
        XCTAssertNotNil(result.result(for: .applicationCaches))
        let snapshot = progress.snapshot()
        XCTAssertEqual(snapshot.completedCategories, snapshot.totalCategories)
        XCTAssertGreaterThan(snapshot.itemsAnalyzed, 0)
        XCTAssertEqual(snapshot.bytesDiscovered, result.reclaimableBytes)
    }

    func testScanIsReadOnly() async throws {
        let file = try fixture.file("Library/Caches/com.example.App/a", bytes: 1_000)
        try fixture.file("Library/Logs/x.log", ageDays: 100)
        try fixture.file(".Trash/t")
        _ = await ScanCoordinator(environment: fixture.environment, settings: UpkeepSettings(), toolRunner: MockToolRunner()).scan()
        XCTAssertTrue(fixture.exists(file))
        XCTAssertTrue(fixture.exists(fixture.home.appendingPathComponent("Library/Logs/x.log")))
        XCTAssertTrue(fixture.exists(fixture.home.appendingPathComponent(".Trash/t")))
    }
}
