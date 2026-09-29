import XCTest
@testable import UpkeepCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class FileSystemTests: XCTestCase {
    var fixture: Fixture!
    let fs = LocalFileSystem()

    override func setUpWithError() throws {
        fixture = try Fixture()
    }

    override func tearDown() {
        fixture = nil
    }

    private func validated(_ url: URL, root: URL) throws -> ValidatedPath {
        try PathValidator(fileSystem: fs, protectedPaths: ProtectedPaths(paths: [])).validate(url, within: root)
    }

    // MARK: Size calculation

    func testMeasureCountsFilesAndLogicalBytes() throws {
        let dir = try fixture.dir("data")
        try fixture.file("data/a.bin", bytes: 1_000)
        try fixture.file("data/sub/b.bin", bytes: 2_500)
        try fixture.file("data/sub/deeper/c.bin", bytes: 10)
        let m = fs.measure(dir)
        XCTAssertEqual(m.fileCount, 3)
        XCTAssertEqual(m.directoryCount, 2)
        XCTAssertEqual(m.logicalBytes, 3_510)
        XCTAssertGreaterThanOrEqual(m.allocatedBytes, 0)
        XCTAssertFalse(m.hasErrors)
    }

    func testMeasureDoesNotFollowSymlinks() throws {
        try fixture.file("big.bin", in: fixture.outside, bytes: 500_000)
        let dir = try fixture.dir("cache")
        try fixture.file("cache/small.bin", bytes: 100)
        _ = try fixture.symlink("cache/link-to-file", to: fixture.outside.appendingPathComponent("big.bin"))
        _ = try fixture.symlink("cache/link-to-dir", to: fixture.outside)
        let m = fs.measure(dir)
        XCTAssertEqual(m.fileCount, 1)
        XCTAssertEqual(m.symlinkCount, 2)
        XCTAssertEqual(m.logicalBytes, 100)
        XCTAssertLessThan(m.allocatedBytes, 500_000)
    }

    func testMeasureCountsHardLinksOnce() throws {
        let dir = try fixture.dir("links")
        let original = try fixture.file("links/a.bin", bytes: 4_096)
        XCTAssertEqual(link(original.path, dir.appendingPathComponent("b.bin").path), 0)
        let m = fs.measure(dir)
        XCTAssertEqual(m.fileCount, 1)
        XCTAssertEqual(m.logicalBytes, 4_096)
    }

    func testMeasureReportsNewestModificationAndSensitiveNames() throws {
        let dir = try fixture.dir("tree")
        try fixture.file("tree/old.txt", ageDays: 30)
        let fresh = try fixture.file("tree/nested/fresh.txt")
        try fixture.file("tree/nested/.env")
        try fixture.dir("tree/repo/.git")
        try fixture.setAge(dir, days: 30)
        let m = fs.measure(dir)
        let freshDate = try fs.info(at: fresh).modificationDate
        XCTAssertEqual(m.newestModification!.timeIntervalSince1970, freshDate.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(m.sensitiveMatches.contains("nested/.env"))
        XCTAssertTrue(m.sensitiveMatches.contains("repo/.git"))
    }

    func testMeasureOfMissingPathIsEmpty() {
        let m = fs.measure(fixture.home.appendingPathComponent("nope"))
        XCTAssertEqual(m.fileCount, 0)
        XCTAssertEqual(m.allocatedBytes, 0)
    }

    func testMeasureVeryLargeDirectory() throws {
        let dir = try fixture.dir("many")
        for index in 0..<5_000 {
            _ = FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(index)").path, contents: Data([1, 2, 3]))
        }
        var progressTotal = 0
        let m = fs.measure(dir, options: MeasureOptions()) { count, _ in progressTotal += count }
        XCTAssertEqual(m.fileCount, 5_000)
        XCTAssertEqual(m.logicalBytes, 15_000)
        XCTAssertEqual(progressTotal, 5_000)
    }

    func testMeasurePermissionDeniedIsCountedNotFatal() throws {
        try XCTSkipIf(Fixture.isRoot, "Permission checks don't apply to root.")
        let dir = try fixture.dir("locked")
        try fixture.file("locked/inner/secret", bytes: 10)
        try fixture.file("locked/visible", bytes: 20)
        chmod(dir.appendingPathComponent("inner").path, 0o000)
        let m = fs.measure(dir)
        XCTAssertEqual(m.permissionDeniedCount, 1)
        XCTAssertEqual(m.logicalBytes, 20)
    }

    // MARK: Listing

    func testContentsOfSymlinkedDirectoryIsRefused() throws {
        let link = try fixture.symlink("link", to: fixture.outside)
        XCTAssertThrowsError(try fs.contentsOfDirectory(at: link)) { error in
            XCTAssertEqual(error as? FileSystemError, .symlinkRefused(link.path))
        }
    }

    // MARK: Removal

    func testRemoveDirectoryTree() throws {
        let root = try fixture.dir("Library/Caches")
        let item = try fixture.dir("Library/Caches/com.example.App")
        try fixture.file("Library/Caches/com.example.App/a/b/c.bin", bytes: 100)
        try fixture.file("Library/Caches/com.example.App/d.bin", bytes: 100)
        let report = try fs.removeItem(try validated(item, root: root), expectedIdentity: nil)
        XCTAssertTrue(report.itemRemoved)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(fixture.exists(item))
        XCTAssertTrue(fixture.exists(root))
    }

    func testRemovalUnlinksSymlinksInsideTreeWithoutTouchingTargets() throws {
        let target = try fixture.dir("precious", in: fixture.outside)
        let preciousFile = try fixture.file("precious/data.txt", in: fixture.outside, bytes: 50)
        let root = try fixture.dir("Library/Caches")
        let item = try fixture.dir("Library/Caches/com.example.App")
        _ = try fixture.symlink("Library/Caches/com.example.App/escape", to: target)
        _ = try fixture.symlink("Library/Caches/com.example.App/file-escape", to: preciousFile)
        let report = try fs.removeItem(try validated(item, root: root), expectedIdentity: nil)
        XCTAssertTrue(report.itemRemoved)
        XCTAssertFalse(fixture.exists(item))
        XCTAssertTrue(fixture.exists(preciousFile), "Symlink target must never be removed")
        XCTAssertEqual(try Data(contentsOf: preciousFile).count, 50)
    }

    func testRemovingASymlinkItemIsRefused() throws {
        let root = try fixture.dir("Library/Caches")
        let link = try fixture.symlink("Library/Caches/com.evil.App", to: fixture.outside)
        XCTAssertThrowsError(try fs.removeItem(try validated(link, root: root), expectedIdentity: nil)) { error in
            XCTAssertEqual(error as? FileSystemError, .symlinkRefused(link.path))
        }
        XCTAssertTrue(fixture.exists(fixture.outside))
    }

    func testIntermediateComponentSwappedForSymlinkIsRefused() throws {
        // Validate, then swap a parent directory for a symlink (a TOCTOU attack).
        let root = try fixture.dir("Library/Caches")
        let parent = try fixture.dir("Library/Caches/org.swift.swiftpm")
        let item = try fixture.dir("Library/Caches/org.swift.swiftpm/repositories")
        let target = try validated(item, root: root)

        let decoy = try fixture.dir("repositories", in: fixture.outside)
        let victim = try fixture.file("repositories/keep.txt", in: fixture.outside)
        try FileManager.default.removeItem(at: parent)
        _ = try fixture.symlink("Library/Caches/org.swift.swiftpm", to: fixture.outside)
        XCTAssertTrue(fixture.exists(decoy))

        XCTAssertThrowsError(try fs.removeItem(target, expectedIdentity: nil)) { error in
            XCTAssertEqual(error as? FileSystemError, .symlinkRefused(target.path))
        }
        XCTAssertTrue(fixture.exists(victim), "Removal must not follow a swapped-in symlink")
    }

    func testIdentityMismatchIsRefused() throws {
        let root = try fixture.dir("Library/Logs")
        let log = try fixture.file("Library/Logs/app.log")
        let scannedIdentity = try fs.info(at: log).identity
        // Replace atomically; both inodes exist at once, so they must differ.
        let replacement = try fixture.file("Library/Logs/app.log.new", bytes: 999)
        XCTAssertEqual(rename(replacement.path, log.path), 0)
        XCTAssertNotEqual(try fs.info(at: log).identity, scannedIdentity)
        XCTAssertThrowsError(try fs.removeItem(try validated(log, root: root), expectedIdentity: scannedIdentity)) { error in
            XCTAssertEqual(error as? FileSystemError, .identityChanged(log.path))
        }
        XCTAssertTrue(fixture.exists(log))
    }

    func testRemoveMissingItemReportsNotFound() throws {
        let root = try fixture.dir("Library/Logs")
        let log = try fixture.file("Library/Logs/app.log")
        let target = try validated(log, root: root)
        try FileManager.default.removeItem(at: log)
        XCTAssertThrowsError(try fs.removeItem(target, expectedIdentity: nil)) { error in
            XCTAssertEqual(error as? FileSystemError, .notFound(target.path))
        }
    }

    func testRemoveNamesWithSpacesAndUnicode() throws {
        let root = try fixture.dir("Library/Caches")
        let item = try fixture.dir("Library/Caches/com.example.Ünïcødé App 🚀")
        try fixture.file("Library/Caches/com.example.Ünïcødé App 🚀/ファイル name.bin")
        try fixture.file("Library/Caches/com.example.Ünïcødé App 🚀/sub dir/é.txt")
        let report = try fs.removeItem(try validated(item, root: root), expectedIdentity: try fs.info(at: item).identity)
        XCTAssertTrue(report.itemRemoved)
        XCTAssertFalse(fixture.exists(item))
    }

    func testRemoveVeryLargeDirectory() throws {
        let root = try fixture.dir("Library/Caches")
        let item = try fixture.dir("Library/Caches/com.example.Big")
        for sub in 0..<10 {
            let dir = try fixture.dir("Library/Caches/com.example.Big/d\(sub)")
            for index in 0..<500 {
                _ = FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(index)").path, contents: Data([0]))
            }
        }
        let report = try fs.removeItem(try validated(item, root: root), expectedIdentity: nil)
        XCTAssertTrue(report.itemRemoved)
        XCTAssertEqual(report.removedEntries, 5_000 + 10 + 1)
        XCTAssertFalse(fixture.exists(item))
    }

    func testPermissionErrorsDuringRemovalArePartialNotFatal() throws {
        try XCTSkipIf(Fixture.isRoot, "Permission checks don't apply to root.")
        let root = try fixture.dir("Library/Caches")
        let item = try fixture.dir("Library/Caches/com.example.App")
        try fixture.file("Library/Caches/com.example.App/free.bin")
        let locked = try fixture.dir("Library/Caches/com.example.App/locked")
        try fixture.file("Library/Caches/com.example.App/locked/stuck.bin")
        chmod(locked.path, 0o500) // can't delete entries inside
        let report = try fs.removeItem(try validated(item, root: root), expectedIdentity: nil)
        XCTAssertFalse(report.itemRemoved)
        XCTAssertFalse(report.failures.isEmpty)
        XCTAssertFalse(fixture.exists(item.appendingPathComponent("free.bin")))
        XCTAssertTrue(fixture.exists(locked.appendingPathComponent("stuck.bin")))
    }
}
