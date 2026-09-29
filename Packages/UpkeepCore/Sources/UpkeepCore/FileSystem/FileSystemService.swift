import Foundation

/// Abstraction over the file system so scanners and the cleanup engine can be
/// tested against fixtures and fault-injecting doubles.
///
/// Implementations must never follow symbolic links when inspecting, measuring
/// or removing items.
public protocol FileSystemService: Sendable {
    /// `lstat`-style metadata. Throws `FileSystemError`.
    func info(at url: URL) throws -> FileInfo

    /// Direct children of a directory (no `.`/`..`). Does not follow a symlinked directory.
    func contentsOfDirectory(at url: URL) throws -> [URL]

    /// Recursively measures a path without following symlinks or crossing volumes.
    func measure(_ url: URL, options: MeasureOptions, onProgress: ((Int, String) -> Void)?) -> DiskUsage

    /// Canonical path with all symlinks resolved. Throws if the path doesn't exist.
    func canonicalPath(_ url: URL) throws -> String

    /// Removes a validated item. The implementation walks from the approved root
    /// with `O_NOFOLLOW` at every step and refuses to follow symlinks or cross volumes.
    func removeItem(_ target: ValidatedPath, expectedIdentity: FileIdentity?) throws -> RemovalReport

    /// Moves a validated item to the user's Trash.
    func moveToTrash(_ target: ValidatedPath, expectedIdentity: FileIdentity?) throws

    var supportsTrash: Bool { get }
}

extension FileSystemService {
    public func exists(_ url: URL) -> Bool {
        (try? info(at: url)) != nil
    }

    public func measure(_ url: URL, options: MeasureOptions = MeasureOptions()) -> DiskUsage {
        measure(url, options: options, onProgress: nil)
    }
}
