import Foundation

public enum FileType: String, Codable, Sendable {
    case regular
    case directory
    case symlink
    case other
}

/// Metadata for a single path, obtained with `lstat` (symbolic links are never followed).
public struct FileInfo: Hashable, Sendable {
    public let url: URL
    public let type: FileType
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let modificationDate: Date
    public let identity: FileIdentity
    public let ownerUID: UInt32
    public let linkCount: UInt64
    /// macOS "dataless" files (e.g. evicted iCloud Drive files) occupy almost no local space.
    public let isDataless: Bool

    public init(
        url: URL,
        type: FileType,
        logicalSize: Int64,
        allocatedSize: Int64,
        modificationDate: Date,
        identity: FileIdentity,
        ownerUID: UInt32,
        linkCount: UInt64,
        isDataless: Bool = false
    ) {
        self.url = url
        self.type = type
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.identity = identity
        self.ownerUID = ownerUID
        self.linkCount = linkCount
        self.isDataless = isDataless
    }

    public var isDirectory: Bool { type == .directory }
    public var isSymlink: Bool { type == .symlink }
}

public enum FileSystemError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case permissionDenied(String)
    case notADirectory(String)
    case symlinkRefused(String)
    case identityChanged(String)
    case outsideApprovedRoot(String)
    case protectedPath(String)
    case invalidPath(String)
    case differentVolume(String)
    case tooDeep(String)
    case unsupported(String)
    case io(code: Int32, path: String, message: String)

    public var description: String {
        switch self {
        case .notFound: return "The item no longer exists."
        case .permissionDenied: return "macOS denied access."
        case .notADirectory: return "Expected a folder but found a file."
        case .symlinkRefused: return "Symbolic links are never followed or removed."
        case .identityChanged: return "The item was replaced after the scan."
        case .outsideApprovedRoot: return "The item is outside the approved cleanup locations."
        case .protectedPath: return "The item is in a protected location."
        case .invalidPath: return "The path is not valid."
        case .differentVolume: return "The item is on a different volume."
        case .tooDeep: return "The folder is nested too deeply to remove safely."
        case .unsupported(let what): return "Not supported: \(what)"
        case .io(_, _, let message): return message
        }
    }

    public var isPermissionError: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// Result of recursively measuring a path.
public struct DiskUsage: Hashable, Sendable {
    public var allocatedBytes: Int64 = 0
    public var logicalBytes: Int64 = 0
    public var fileCount: Int = 0
    public var directoryCount: Int = 0
    public var symlinkCount: Int = 0
    public var newestModification: Date?
    /// Relative paths of entries whose names suggest credentials or source history (capped).
    public var sensitiveMatches: [String] = []
    public var permissionDeniedCount: Int = 0
    public var otherErrorCount: Int = 0
    public var skippedOtherVolumeCount: Int = 0
    public var truncated: Bool = false
    public var cancelled: Bool = false

    public init() {}

    public var hasErrors: Bool { permissionDeniedCount > 0 || otherErrorCount > 0 }
}

public struct MeasureOptions: Sendable {
    public var detectSensitiveNames: Bool
    public var maxDepth: Int
    public var maxEntries: Int

    public init(detectSensitiveNames: Bool = true, maxDepth: Int = 64, maxEntries: Int = 5_000_000) {
        self.detectSensitiveNames = detectSensitiveNames
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
    }
}

/// Outcome of a confined recursive removal.
public struct RemovalReport: Hashable, Sendable {
    public var removedEntries: Int = 0
    public var failures: [String] = []
    public var itemRemoved: Bool = false

    public init() {}
}
