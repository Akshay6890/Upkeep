import XCTest
@testable import UpkeepCore

final class RuleTests: XCTestCase {
    var fixture: Fixture!
    var caches: URL!

    override func setUpWithError() throws {
        fixture = try Fixture()
        caches = try fixture.dir("Library/Caches")
    }

    override func tearDown() {
        fixture = nil
    }

    // MARK: Bundle identifiers

    func testBundleIdentifierDetection() {
        for name in ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "io.sentry", "com.example.My-App_2"] {
            XCTAssertTrue(RuleBook.looksLikeBundleIdentifier(name), name)
        }
        for name in ["Google", "RandomThing", "com..App", ".hidden", "Com.Example.App", "a.b", "com.exa mple.App", "1com.example.x", "zz.thing"] {
            XCTAssertFalse(RuleBook.looksLikeBundleIdentifier(name), name)
        }
    }

    // MARK: Application caches

    func verdict(_ rule: CleanupRuleID, _ url: URL, root: URL, kind: RootKind, context: RuleContext? = nil, childNames: Bool = false) throws -> RuleVerdict {
        let c = try candidate(url, root: root, kind: kind, childNames: childNames)
        return RuleBook.rule(for: rule).evaluate(c, context: context ?? ruleContext(fixture))
    }

    func testAppCacheWithBundleIdentifierIsSafe() throws {
        let dir = try fixture.dir("Library/Caches/com.example.App")
        try fixture.file("Library/Caches/com.example.App/blob")
        guard case .candidate(let risk, _, _) = try verdict(.applicationCache, dir, root: caches, kind: .caches) else {
            return XCTFail("expected candidate")
        }
        XCTAssertEqual(risk, .safe)
    }

    func testAppCacheOfRunningAppNeedsReview() throws {
        let dir = try fixture.dir("Library/Caches/com.example.App")
        let context = ruleContext(fixture, running: ["com.example.App"])
        guard case .candidate(let risk, _, let notes) = try verdict(.applicationCache, dir, root: caches, kind: .caches, context: context) else {
            return XCTFail("expected candidate")
        }
        XCTAssertEqual(risk, .review)
        XCTAssertTrue(notes.contains { $0.contains("running") })
    }

    func testUnclassifiableCacheIsProtected() throws {
        let dir = try fixture.dir("Library/Caches/SomethingElse")
        guard case .protected = try verdict(.applicationCache, dir, root: caches, kind: .caches) else {
            return XCTFail("expected protected")
        }
    }

    func testSystemServiceCachesAreProtected() throws {
        for name in ["com.apple.bird", "CloudKit", "com.apple.nsurlsessiond", "com.apple.icloud.searchpartyd"] {
            let dir = try fixture.dir("Library/Caches/\(name)")
            guard case .protected = try verdict(.applicationCache, dir, root: caches, kind: .caches) else {
                return XCTFail("\(name) should be protected")
            }
        }
    }

    func testCacheContainingGitRepositoryIsProtected() throws {
        let dir = try fixture.dir("Library/Caches/com.example.App")
        try fixture.dir("Library/Caches/com.example.App/checkout/.git")
        guard case .protected(let reason) = try verdict(.applicationCache, dir, root: caches, kind: .caches) else {
            return XCTFail("expected protected")
        }
        XCTAssertTrue(reason.contains(".git"))
    }

    func testClaimedCachesAreLeftToTheirScanner() throws {
        for name in ["org.swift.swiftpm", "Yarn", "pip"] {
            let dir = try fixture.dir("Library/Caches/\(name)")
            guard case .ignore = try verdict(.applicationCache, dir, root: caches, kind: .caches) else {
                return XCTFail("\(name) should be ignored by the app cache rule")
            }
        }
    }

    func testHomebrewCacheDependsOnInstallation() throws {
        let dir = try fixture.dir("Library/Caches/Homebrew")
        guard case .ignore = try verdict(.applicationCache, dir, root: caches, kind: .caches, context: ruleContext(fixture, homebrew: true)) else {
            return XCTFail("installed: handled by brew")
        }
        guard case .candidate(.safe, _, _) = try verdict(.applicationCache, dir, root: caches, kind: .caches, context: ruleContext(fixture, homebrew: false)) else {
            return XCTFail("not installed: leftover")
        }
    }

    func testLooseFilesAndNestedFoldersInCachesAreIgnored() throws {
        let file = try fixture.file("Library/Caches/com.example.plist")
        guard case .ignore = try verdict(.applicationCache, file, root: caches, kind: .caches) else { return XCTFail() }
        let nested = try fixture.dir("Library/Caches/com.example.App/Sub")
        guard case .ignore = try verdict(.applicationCache, nested, root: caches, kind: .caches) else { return XCTFail() }
    }

    func testSymlinkIsNeverACandidate() throws {
        let link = try fixture.symlink("Library/Caches/com.example.Link", to: fixture.outside)
        guard case .ignore = try verdict(.applicationCache, link, root: caches, kind: .caches) else { return XCTFail() }
    }

    // MARK: Age filtering

    func testLogAgeThreshold() throws {
        let logs = try fixture.dir("Library/Logs")
        let old = try fixture.file("Library/Logs/App/old.log", ageDays: 20)
        let recent = try fixture.file("Library/Logs/App/recent.log", ageDays: 2)
        var settings = UpkeepSettings()
        settings.logMinimumAgeDays = 14
        let context = ruleContext(fixture, settings: settings)
        XCTAssertTrue(try verdict(.userLog, old, root: logs, kind: .logs, context: context).isCandidate)
        XCTAssertFalse(try verdict(.userLog, recent, root: logs, kind: .logs, context: context).isCandidate)
        settings.logMinimumAgeDays = 30
        XCTAssertFalse(try verdict(.userLog, old, root: logs, kind: .logs, context: ruleContext(fixture, settings: settings)).isCandidate)
    }

    func testLogRuleSkipsDiagnosticReports() throws {
        let logs = try fixture.dir("Library/Logs")
        let report = try fixture.file("Library/Logs/DiagnosticReports/App-2020-01-01-000000.ips", ageDays: 100)
        XCTAssertFalse(try verdict(.userLog, report, root: logs, kind: .logs).isCandidate)
    }

    func testCrashReportAgeAndExtension() throws {
        let reports = try fixture.dir("Library/Logs/DiagnosticReports")
        let old = try fixture.file("Library/Logs/DiagnosticReports/Safari-2024-01-01-101010.ips", ageDays: 45)
        let recent = try fixture.file("Library/Logs/DiagnosticReports/Safari-2024-03-01-101010.ips", ageDays: 5)
        let other = try fixture.file("Library/Logs/DiagnosticReports/notes.txt", ageDays: 45)
        XCTAssertTrue(try verdict(.crashReport, old, root: reports, kind: .diagnosticReports).isCandidate)
        XCTAssertFalse(try verdict(.crashReport, recent, root: reports, kind: .diagnosticReports).isCandidate)
        XCTAssertFalse(try verdict(.crashReport, other, root: reports, kind: .diagnosticReports).isCandidate)
        var settings = UpkeepSettings()
        settings.crashReportMinimumAgeDays = 60
        XCTAssertFalse(try verdict(.crashReport, old, root: reports, kind: .diagnosticReports, context: ruleContext(fixture, settings: settings)).isCandidate)
    }

    func testCrashReportApplicationName() {
        XCTAssertEqual(RuleBook.applicationName(fromReportName: "Safari-2024-05-01-101010.ips"), "Safari")
        XCTAssertEqual(RuleBook.applicationName(fromReportName: "Google Chrome Helper-2024-05-01-101010.ips"), "Google Chrome Helper")
        XCTAssertEqual(RuleBook.applicationName(fromReportName: "Xcode_2024-05-01-101010_Mac.diag"), "Xcode")
        XCTAssertEqual(RuleBook.applicationName(fromReportName: "weird.crash"), "weird")
    }

    func testTemporaryItemUsesNewestContentAge() throws {
        let stale = try fixture.dir("stale", in: fixture.tmp)
        try fixture.file("stale/a", in: fixture.tmp, ageDays: 10)
        try fixture.setAge(stale, days: 10)
        XCTAssertTrue(try verdict(.staleTemporaryItem, stale, root: fixture.tmp, kind: .temporary).isCandidate)

        let active = try fixture.dir("active", in: fixture.tmp)
        try fixture.file("active/fresh", in: fixture.tmp)
        try fixture.setAge(active, days: 10) // folder looks old, but content is fresh
        XCTAssertFalse(try verdict(.staleTemporaryItem, active, root: fixture.tmp, kind: .temporary).isCandidate)

        let system = try fixture.file("com.apple.something", in: fixture.tmp, ageDays: 30)
        XCTAssertFalse(try verdict(.staleTemporaryItem, system, root: fixture.tmp, kind: .temporary).isCandidate)
    }

    // MARK: Risk classification

    func testDeveloperRiskClassification() throws {
        let derived = try fixture.dir("Library/Developer/Xcode/DerivedData")
        let project = try fixture.dir("Library/Developer/Xcode/DerivedData/App-abc")
        try fixture.dir("Library/Developer/Xcode/DerivedData/App-abc/SourcePackages/checkouts/dep/.git")
        guard case .candidate(.safe, _, _) = try verdict(.xcodeDerivedData, project, root: derived, kind: .derivedData) else {
            return XCTFail("DerivedData should be safe even with dependency checkouts")
        }
        guard case .candidate(.review, _, _) = try verdict(.xcodeDerivedData, project, root: derived, kind: .derivedData, context: ruleContext(fixture, running: ["com.apple.dt.Xcode"])) else {
            return XCTFail("DerivedData needs review while Xcode runs")
        }

        let archives = try fixture.dir("Library/Developer/Xcode/Archives")
        let archive = try fixture.dir("Library/Developer/Xcode/Archives/2024-01-01/App 1-1-24.xcarchive")
        try fixture.file("Library/Developer/Xcode/Archives/2024-01-01/App 1-1-24.xcarchive/Info.plist")
        guard case .candidate(.review, _, _) = try verdict(.xcodeArchive, archive, root: archives, kind: .xcodeArchives) else {
            return XCTFail("Archives must be review")
        }

        let support = try fixture.dir("Library/Developer/Xcode/iOS DeviceSupport")
        let version = try fixture.dir("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)")
        guard case .candidate(.review, _, _) = try verdict(.xcodeDeviceSupport, version, root: support, kind: .deviceSupport) else {
            return XCTFail("Device support must be review")
        }
    }

    func testTrashItemsAreReviewAndPermanent() throws {
        let trash = try fixture.dir(".Trash")
        let item = try fixture.dir(".Trash/Old Project")
        try fixture.dir(".Trash/Old Project/.git")
        guard case .candidate(let risk, _, let notes) = try verdict(.trashItem, item, root: trash, kind: .trash) else {
            return XCTFail("expected candidate")
        }
        XCTAssertEqual(risk, .review)
        XCTAssertTrue(notes.contains { $0.contains(".git") })
        XCTAssertEqual(RuleBook.rule(for: .trashItem).allowedMethods, [.deletePermanently])
    }

    func testYarnRuleDependsOnRootKind() throws {
        let yarn = try fixture.dir("Library/Caches/Yarn")
        XCTAssertTrue(try verdict(.yarnCache, yarn, root: caches, kind: .caches).isCandidate)
        let lookalike = try fixture.dir("Library/Caches/cache")
        XCTAssertFalse(try verdict(.yarnCache, lookalike, root: caches, kind: .caches).isCandidate)
        let berryRoot = try fixture.dir(".yarn/berry")
        let berry = try fixture.dir(".yarn/berry/cache")
        XCTAssertTrue(try verdict(.yarnCache, berry, root: berryRoot, kind: .yarnBerry).isCandidate)
    }

    func testPythonBytecodeRule() throws {
        let project = try fixture.dir("code/app", in: fixture.root)
        let clean = try fixture.dir("code/app/__pycache__", in: fixture.root)
        try fixture.file("code/app/__pycache__/mod.cpython-312.pyc", in: fixture.root)
        guard case .candidate(.safe, _, _) = try verdict(.pythonBytecode, clean, root: project, kind: .developerFolder, childNames: true) else {
            return XCTFail("bytecode-only __pycache__ should be safe")
        }
        try fixture.file("code/app/__pycache__/notes.py", in: fixture.root)
        guard case .protected = try verdict(.pythonBytecode, clean, root: project, kind: .developerFolder, childNames: true) else {
            return XCTFail("mixed content must be protected")
        }
        let other = try fixture.dir("code/app/src", in: fixture.root)
        XCTAssertFalse(try verdict(.pythonBytecode, other, root: project, kind: .developerFolder, childNames: true).isCandidate)
    }

    func testRuleMethodAllowlists() {
        XCTAssertTrue(RuleBook.rule(for: .applicationCache).allows(.delete))
        XCTAssertFalse(RuleBook.rule(for: .applicationCache).allows(.tool(.homebrewCleanup)))
        XCTAssertFalse(RuleBook.rule(for: .largeFile).allows(.delete))
        XCTAssertTrue(RuleBook.rule(for: .npmCache).allows(.tool(.npmCacheClean)))
        XCTAssertFalse(RuleBook.rule(for: .npmCache).allows(.tool(.yarnCacheClean)))
        XCTAssertTrue(RuleBook.rule(for: .unavailableSimulator).allows(.tool(.simctlDeleteDevice(udid: UUID().uuidString))))
        XCTAssertFalse(RuleBook.rule(for: .unavailableSimulator).isFileSystemRule)
    }

    func testSensitiveNameDetection() {
        XCTAssertTrue(SensitiveNames.isSensitive(name: ".git", isDirectory: true))
        XCTAssertTrue(SensitiveNames.isSensitive(name: ".env.production", isDirectory: false))
        XCTAssertTrue(SensitiveNames.isSensitive(name: "cert.p12", isDirectory: false))
        XCTAssertTrue(SensitiveNames.containsSensitiveComponent(["project", ".git", "config"]))
        XCTAssertFalse(SensitiveNames.isSensitive(name: "environment.json", isDirectory: false))
        XCTAssertFalse(SensitiveNames.isSensitive(name: "cache.db", isDirectory: false))
    }
}
