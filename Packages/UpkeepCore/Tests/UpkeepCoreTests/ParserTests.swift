import XCTest
@testable import UpkeepCore

final class ParserTests: XCTestCase {
    func testHomebrewSizeParsing() {
        XCTAssertEqual(HomebrewOutputParser.parseSize("512B"), 512)
        XCTAssertEqual(HomebrewOutputParser.parseSize("1KB"), 1_024)
        XCTAssertEqual(HomebrewOutputParser.parseSize("1.5MB"), 1_572_864)
        XCTAssertEqual(HomebrewOutputParser.parseSize("2GB"), 2_147_483_648)
        XCTAssertNil(HomebrewOutputParser.parseSize("lots"))
        XCTAssertNil(HomebrewOutputParser.parseSize("-1MB"))
    }

    func testHomebrewDryRunParsing() {
        let output = """
        Would remove: /Users/me/Library/Caches/Homebrew/downloads/abc--node-21.1.0.bottle.tar.gz (15.8MB)
        Would remove: /Users/me/Library/Caches/Homebrew/wget--1.21.bottle.tar.gz (1.2MB)
        Would remove: /opt/homebrew/Cellar/python@3.11/3.11.5 (3,212 files, 64.5MB)
        Would remove: /opt/homebrew/Caskroom/firefox/118.0 (1 file, 120MB)
        Would remove: /Users/me/Library/Logs/Homebrew/wget (2 files, 3.4KB)
        Would remove: /opt/homebrew/lib/broken-link (symlink)
        Warning: Skipping something: unrelated
        ==> This operation would free approximately 204.9MB of disk space.
        """
        let preview = HomebrewOutputParser.parseCleanupDryRun(output, cacheDirectory: "/Users/me/Library/Caches/Homebrew")
        XCTAssertEqual(preview.entries.count, 6)
        XCTAssertEqual(preview.count(of: .cachedDownload), 2)
        XCTAssertEqual(preview.count(of: .oldVersion), 2)
        XCTAssertEqual(preview.count(of: .other), 2)
        XCTAssertEqual(preview.entries[2].bytes, HomebrewOutputParser.parseSize("64.5MB"))
        XCTAssertEqual(preview.entries[5].bytes, 0)
        XCTAssertEqual(preview.totalBytes, HomebrewOutputParser.parseSize("204.9MB"))
    }

    func testHomebrewDryRunWithoutTotalSumsEntries() {
        let output = "Would remove: /opt/homebrew/Cellar/a/1 (1KB)\nWould remove: /opt/homebrew/Cellar/b/2 (2KB)\n"
        let preview = HomebrewOutputParser.parseCleanupDryRun(output, cacheDirectory: nil)
        XCTAssertNil(preview.reportedTotalBytes)
        XCTAssertEqual(preview.totalBytes, 3_072)
    }

    func testHomebrewEmptyOutput() {
        XCTAssertEqual(HomebrewOutputParser.parseCleanupDryRun("", cacheDirectory: nil).totalBytes, 0)
    }

    func testSimctlParsing() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
            {"udid": "11111111-2222-3333-4444-555555555555", "name": "iPhone 14", "isAvailable": false,
             "availabilityError": "runtime profile not found", "dataPath": "/x/data", "state": "Shutdown"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
            {"udid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "name": "iPhone 15", "isAvailable": true, "state": "Shutdown"}
          ]
        }}
        """
        let devices = try SimctlParser.parseDevices(Data(json.utf8))
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.filter { !$0.device.isAvailable }.map(\.device.name), ["iPhone 14"])
        XCTAssertEqual(SimctlParser.runtimeDisplayName("com.apple.CoreSimulator.SimRuntime.iOS-16-4"), "iOS 16.4")
    }

    func testUDIDValidationRejectsInjection() {
        XCTAssertTrue(SimctlParser.isValidUDID("11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(SimctlParser.isValidUDID("all"))
        XCTAssertFalse(SimctlParser.isValidUDID("unavailable"))
        XCTAssertFalse(SimctlParser.isValidUDID("11111111-2222-3333-4444-555555555555; rm -rf ~"))
    }

    func testFormatting() {
        XCTAssertEqual(Formatting.bytes(0), "0 bytes")
        XCTAssertEqual(Formatting.bytes(742_000), "742 KB")
        XCTAssertEqual(Formatting.bytes(842_000_000), "842 MB")
        XCTAssertEqual(Formatting.bytes(3_400_000), "3.4 MB")
        XCTAssertEqual(Formatting.bytes(12_800_000_000), "12.8 GB")
        XCTAssertEqual(Formatting.count(1_284), "1,284")
        XCTAssertEqual(Formatting.plural(1, "file"), "1 file")
        XCTAssertEqual(Formatting.plural(3_921, "file"), "3,921 files")
    }
}
