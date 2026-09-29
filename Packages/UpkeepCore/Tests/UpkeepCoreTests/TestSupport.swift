import Foundation
import XCTest
@testable import UpkeepCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A throwaway directory tree that stands in for a user's home folder.
/// Tests never touch real user directories: every path used by the engine is
/// derived from `environment`, which points inside this fixture.
final class Fixture {
    let root: URL
    let home: URL
    let tmp: URL
    let outside: URL
    let bin: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
        // Canonicalize so comparisons with realpath() results are stable (/var → /private/var on macOS).
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try LocalFileSystem().canonicalPath(base), isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        tmp = root.appendingPathComponent("tmp", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        for dir in [home, tmp, outside, bin] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        // Restore permissions so cleanup of the fixture itself can't fail.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                chmod(root.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    var environment: ScanEnvironment {
        ScanEnvironment(
            homeDirectory: home,
            temporaryDirectory: tmp,
            homebrewExecutableCandidates: [bin.appendingPathComponent("brew")],
            xcodeApplicationCandidates: [root.appendingPathComponent("Applications/Xcode.app")],
            developerFolders: [],
            toolSearchDirectories: [bin],
            xcrunURL: bin.appendingPathComponent("xcrun")
        )
    }

    @discardableResult
    func dir(_ relative: String, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, in base: URL? = nil, bytes: Int = 16, ageDays: Double? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: url)
        if let ageDays { try setAge(url, days: ageDays) }
        return url
    }

    func setAge(_ url: URL, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        var times = [timeval](repeating: timeval(), count: 2)
        let seconds = Int(date.timeIntervalSince1970)
        times[0].tv_sec = time_t(seconds)
        times[1].tv_sec = time_t(seconds)
        let result = url.path.withCString { lutimes($0, times) }
        XCTAssertEqual(result, 0, "lutimes failed for \(url.path)")
    }

    func symlink(_ relative: String, to destination: URL, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination.path)
        return url
    }

    /// Writes an executable script (used only so ToolLocator finds a "tool";
    /// tests use MockToolRunner and never execute it).
    @discardableResult
    func fakeTool(_ name: String) throws -> URL {
        let url = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        return url
    }

    func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static var isRoot: Bool { getuid() == 0 }
}

/// Records tool invocations and returns canned output. Never launches processes.
final class MockToolRunner: ToolRunning, @unchecked Sendable {
    typealias Handler = (URL, [String]) throws -> ToolOutput
    private let lock = NSLock()
    private var handler: Handler
    private(set) var calls: [(URL, [String])] = []

    init(handler: @escaping Handler = { _, _ in ToolOutput(exitCode: 0, standardOutput: "", standardError: "") }) {
        self.handler = handler
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> ToolOutput {
        try record(executable, arguments)(executable, arguments)
    }

    private func record(_ executable: URL, _ arguments: [String]) -> Handler {
        lock.lock()
        defer { lock.unlock() }
        calls.append((executable, arguments))
        return handler
    }

    var recordedArguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.1)
    }
}

/// Wraps the real file system and injects faults for specific paths.
final class FaultInjectingFileSystem: FileSystemService, @unchecked Sendable {
    let base = LocalFileSystem()
    var failRemovalWith: [String: FileSystemError] = [:]
    var afterRemoval: ((ValidatedPath) -> Void)?
    var beforeRemoval: ((ValidatedPath) -> Void)?
    var trashSupported = false
    private(set) var trashed: [String] = []

    func info(at url: URL) throws -> FileInfo { try base.info(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func measure(_ url: URL, options: MeasureOptions, onProgress: ((Int, String) -> Void)?) -> DiskUsage {
        base.measure(url, options: options, onProgress: onProgress)
    }
    func canonicalPath(_ url: URL) throws -> String { try base.canonicalPath(url) }

    func removeItem(_ target: ValidatedPath, expectedIdentity: FileIdentity?) throws -> RemovalReport {
        beforeRemoval?(target)
        if let error = failRemovalWith[target.path] { throw error }
        let report = try base.removeItem(target, expectedIdentity: expectedIdentity)
        afterRemoval?(target)
        return report
    }

    func moveToTrash(_ target: ValidatedPath, expectedIdentity: FileIdentity?) throws {
        trashed.append(target.path)
        _ = try base.removeItem(target, expectedIdentity: expectedIdentity)
    }

    var supportsTrash: Bool { trashSupported }
}

extension XCTestCase {
    func ruleContext(_ fixture: Fixture, settings: UpkeepSettings = UpkeepSettings(), running: Set<String> = [], homebrew: Bool = false) -> RuleContext {
        RuleContext(settings: settings, now: Date(), currentUserID: fixture.environment.currentUserID, runningBundleIdentifiers: running, homebrewInstalled: homebrew)
    }

    func candidate(_ url: URL, root: URL, kind: RootKind, measure: Bool = true, childNames: Bool = false) throws -> RuleCandidate {
        let fs = LocalFileSystem()
        let info = try fs.info(at: url)
        let rootPath = try fs.canonicalPath(root)
        let itemPath = try fs.canonicalPath(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
        let relative = String(itemPath.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
        return RuleCandidate(
            url: url, info: info, rootKind: kind, relativeComponents: relative,
            measurement: measure ? fs.measure(url) : nil,
            childNames: childNames ? try fs.contentsOfDirectory(at: url).map(\.lastPathComponent) : nil
        )
    }

    func scanContext(_ fixture: Fixture, settings: UpkeepSettings = UpkeepSettings(), runner: ToolRunning = MockToolRunner(), fileSystem: FileSystemService = LocalFileSystem(), environment: ScanEnvironment? = nil) -> ScanContext {
        let env = environment ?? fixture.environment
        let locator = ToolLocator(environment: env, fileSystem: fileSystem)
        return ScanContext(
            environment: env, settings: settings, fileSystem: fileSystem,
            ruleContext: RuleContext(settings: settings, now: Date(), currentUserID: env.currentUserID, homebrewInstalled: locator.locate(.brew) != nil),
            progress: ScanProgressReporter(), toolRunner: runner
        )
    }
}
