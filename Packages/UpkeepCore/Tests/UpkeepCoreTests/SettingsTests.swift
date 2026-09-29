import XCTest
@testable import UpkeepCore

final class SettingsTests: XCTestCase {
    func testDefaultsAreConservative() {
        let settings = UpkeepSettings()
        XCTAssertEqual(settings.scanFrequency, .manual)
        XCTAssertTrue(settings.confirmBeforeCleanup)
        XCTAssertFalse(settings.showProtectedItems)
        XCTAssertFalse(settings.notifyAfterScheduledScan)
        XCTAssertEqual(settings.crashReportMinimumAgeDays, 30)
        XCTAssertEqual(settings.largeFileThresholdBytes, 1_000_000_000)
    }

    func testDecodingIsTolerantOfMissingAndUnknownKeys() throws {
        let json = #"{"includeLogs": false, "logMinimumAgeDays": 60, "someFutureSetting": true}"#
        let settings = try JSONDecoder().decode(UpkeepSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.includeLogs)
        XCTAssertEqual(settings.logMinimumAgeDays, 60)
        XCTAssertTrue(settings.confirmBeforeCleanup)
    }

    func testRoundTrip() throws {
        var settings = UpkeepSettings()
        settings.scanFrequency = .weekly
        settings.moveToTrashWhenPossible = true
        let decoded = try JSONDecoder().decode(UpkeepSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testNormalizationClampsValues() {
        var settings = UpkeepSettings()
        settings.logMinimumAgeDays = 0
        settings.crashReportMinimumAgeDays = 10_000
        settings.largeFileThresholdBytes = 1
        let normalized = settings.normalized()
        XCTAssertEqual(normalized.logMinimumAgeDays, 1)
        XCTAssertEqual(normalized.crashReportMinimumAgeDays, 365)
        XCTAssertEqual(normalized.largeFileThresholdBytes, 50_000_000)
    }

    func testCategoryToggles() {
        var settings = UpkeepSettings()
        settings.includeLogs = false
        settings.includeDeveloperCaches = false
        settings.includePackageManagerCaches = false
        XCTAssertFalse(settings.isEnabled(.logs))
        XCTAssertFalse(settings.isEnabled(.crashReports))
        XCTAssertFalse(settings.isEnabled(.xcode))
        XCTAssertFalse(settings.isEnabled(.homebrew))
        XCTAssertFalse(settings.isEnabled(.nodePackageManagers))
        XCTAssertTrue(settings.isEnabled(.applicationCaches))
        XCTAssertTrue(settings.isEnabled(.trash))
    }

    func testRiskOrderingAndDefaults() {
        XCTAssertLessThan(CleanupRisk.safe, .review)
        XCTAssertLessThan(CleanupRisk.review, .protected)
        XCTAssertTrue(CleanupRisk.safe.isSelectedByDefault)
        XCTAssertFalse(CleanupRisk.review.isSelectedByDefault)
        XCTAssertFalse(CleanupRisk.protected.isSelectedByDefault)
    }

    func testStorageProjection() {
        let summary = StorageSummary(totalCapacity: 100, availableCapacity: 40, volumeName: nil)
        XCTAssertEqual(summary.usedCapacity, 60)
        XCTAssertEqual(summary.projectedAvailable(afterFreeing: 10), 50)
        XCTAssertEqual(summary.projectedAvailable(afterFreeing: 1_000), 100)
    }

    func testDiskSpaceServiceReadsRealVolume() throws {
        let summary = try DiskSpaceService().storageSummary(for: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertGreaterThan(summary.totalCapacity, 0)
        XCTAssertGreaterThan(summary.availableCapacity, 0)
        XCTAssertLessThanOrEqual(summary.availableCapacity, summary.totalCapacity)
    }
}
