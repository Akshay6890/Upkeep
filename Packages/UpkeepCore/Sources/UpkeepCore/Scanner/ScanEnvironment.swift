import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Kinds of approved cleanup roots. File-system cleanup is only ever performed
/// strictly inside one of these, and each rule lists the kinds it may use.
public enum RootKind: String, Codable, Sendable, CaseIterable {
    case caches
    case logs
    case diagnosticReports
    case trash
    case temporary
    case derivedData
    case xcodeArchives
    case deviceSupport
    case simulatorCaches
    case npm
    case yarnBerry
    case pnpmHome
    case developerFolder
}

public struct ApprovedRoot: Hashable, Sendable {
    public let kind: RootKind
    public let url: URL

    public init(kind: RootKind, url: URL) {
        self.kind = kind
        self.url = url
    }
}

/// Where things live on this Mac. Everything a scanner reads is derived from this
/// value, which lets tests point the whole engine at a temporary fixture tree.
public struct ScanEnvironment: Sendable {
    public var homeDirectory: URL
    public var temporaryDirectory: URL
    public var homebrewExecutableCandidates: [URL]
    public var xcodeApplicationCandidates: [URL]
    /// Folders the user explicitly approved for scanning (Python bytecode caches).
    public var developerFolders: [URL]
    /// Extra directories searched for npm/yarn/pnpm, in priority order.
    public var toolSearchDirectories: [URL]
    public var xcrunURL: URL
    public var currentUserID: UInt32

    public init(
        homeDirectory: URL,
        temporaryDirectory: URL,
        homebrewExecutableCandidates: [URL] = [],
        xcodeApplicationCandidates: [URL] = [],
        developerFolders: [URL] = [],
        toolSearchDirectories: [URL] = [],
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        currentUserID: UInt32 = UInt32(getuid())
    ) {
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.homebrewExecutableCandidates = homebrewExecutableCandidates
        self.xcodeApplicationCandidates = xcodeApplicationCandidates
        self.developerFolders = developerFolders
        self.toolSearchDirectories = toolSearchDirectories
        self.xcrunURL = xcrunURL
        self.currentUserID = currentUserID
    }

    /// The environment of the current user on this Mac.
    public static func current(developerFolders: [URL] = []) -> ScanEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homebrew = [
            URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            URL(fileURLWithPath: "/usr/local/bin/brew"),
        ]
        let xcode = [
            URL(fileURLWithPath: "/Applications/Xcode.app"),
            URL(fileURLWithPath: "/Applications/Xcode-beta.app"),
        ]
        let toolDirs = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent("Library/pnpm"),
            home.appendingPathComponent(".local/share/pnpm"),
        ]
        return ScanEnvironment(
            homeDirectory: home,
            temporaryDirectory: userTemporaryDirectory(),
            homebrewExecutableCandidates: homebrew,
            xcodeApplicationCandidates: xcode,
            developerFolders: developerFolders,
            toolSearchDirectories: toolDirs
        )
    }

    /// The per-user temporary directory (`/var/folders/…/T` on macOS).
    static func userTemporaryDirectory() -> URL {
        #if os(macOS)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
                let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        #endif
        return FileManager.default.temporaryDirectory
    }

    // MARK: Well-known locations

    public var library: URL { homeDirectory.appendingPathComponent("Library", isDirectory: true) }
    public var caches: URL { library.appendingPathComponent("Caches", isDirectory: true) }
    public var logs: URL { library.appendingPathComponent("Logs", isDirectory: true) }
    public var diagnosticReports: URL { logs.appendingPathComponent("DiagnosticReports", isDirectory: true) }
    public var trash: URL { homeDirectory.appendingPathComponent(".Trash", isDirectory: true) }
    public var developer: URL { library.appendingPathComponent("Developer", isDirectory: true) }
    public var xcodeDeveloper: URL { developer.appendingPathComponent("Xcode", isDirectory: true) }
    public var derivedData: URL { xcodeDeveloper.appendingPathComponent("DerivedData", isDirectory: true) }
    public var xcodeArchives: URL { xcodeDeveloper.appendingPathComponent("Archives", isDirectory: true) }
    public var deviceSupportDirectories: [URL] {
        ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport", "xrOS DeviceSupport"]
            .map { xcodeDeveloper.appendingPathComponent($0, isDirectory: true) }
    }
    public var coreSimulator: URL { developer.appendingPathComponent("CoreSimulator", isDirectory: true) }
    public var simulatorCaches: URL { coreSimulator.appendingPathComponent("Caches", isDirectory: true) }
    public var simulatorDevices: URL { coreSimulator.appendingPathComponent("Devices", isDirectory: true) }
    public var swiftPMCache: URL { caches.appendingPathComponent("org.swift.swiftpm", isDirectory: true) }
    public var npmDirectory: URL { homeDirectory.appendingPathComponent(".npm", isDirectory: true) }
    public var yarnBerryDirectory: URL { homeDirectory.appendingPathComponent(".yarn/berry", isDirectory: true) }
    public var pnpmHome: URL { library.appendingPathComponent("pnpm", isDirectory: true) }

    /// Every approved cleanup root. Nothing outside these is ever removed by Upkeep itself.
    public var approvedRoots: [ApprovedRoot] {
        var roots: [ApprovedRoot] = [
            ApprovedRoot(kind: .caches, url: caches),
            ApprovedRoot(kind: .logs, url: logs),
            ApprovedRoot(kind: .diagnosticReports, url: diagnosticReports),
            ApprovedRoot(kind: .trash, url: trash),
            ApprovedRoot(kind: .temporary, url: temporaryDirectory),
            ApprovedRoot(kind: .derivedData, url: derivedData),
            ApprovedRoot(kind: .xcodeArchives, url: xcodeArchives),
            ApprovedRoot(kind: .simulatorCaches, url: simulatorCaches),
            ApprovedRoot(kind: .npm, url: npmDirectory),
            ApprovedRoot(kind: .yarnBerry, url: yarnBerryDirectory),
            ApprovedRoot(kind: .pnpmHome, url: pnpmHome),
        ]
        roots += deviceSupportDirectories.map { ApprovedRoot(kind: .deviceSupport, url: $0) }
        roots += developerFolders.map { ApprovedRoot(kind: .developerFolder, url: $0) }
        return roots
    }

    public func approvedRoot(matching url: URL, kinds: Set<RootKind>) -> ApprovedRoot? {
        let target = url.standardizedFileURL.path
        return approvedRoots.first { kinds.contains($0.kind) && $0.url.standardizedFileURL.path == target }
    }

    /// Replaces the home directory with `~` for display.
    public func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = homeDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
