import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The real file system, implemented directly on POSIX calls so that symlink
/// handling is explicit and identical on every platform.
///
/// Safety properties:
/// - Metadata comes from `lstat`/`fstatat(AT_SYMLINK_NOFOLLOW)`; links are never followed.
/// - Directories are opened with `O_NOFOLLOW | O_DIRECTORY`.
/// - Removal starts at the approved root's canonical path and descends one
///   component at a time with `openat(O_NOFOLLOW)`, so a symlink swapped into
///   the path after validation makes the operation fail instead of escaping.
/// - Recursive removal never crosses onto another volume and only ever unlinks
///   a symlink itself, never its target.
public struct LocalFileSystem: FileSystemService {
    /// Maximum nesting depth removal will descend into (each level holds one file descriptor).
    public static let maxRemovalDepth = 96
    private static let maxRecordedFailures = 50
    private static let maxSensitiveMatches = 5

    public init() {}

    public var supportsTrash: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    // MARK: Inspection

    public func info(at url: URL) throws -> FileInfo {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw FileSystemError.from(errno: errno, path: path)
        }
        return FileInfo(url: url, stat: st)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        let path = url.path
        let fd = try POSIXDirectory.openDirectory(atFD: AT_FDCWD, path, reportedPath: path)
        defer { close(fd) }
        let names = try POSIXDirectory.entryNames(directoryFD: fd, path: path)
        return names.map { url.appendingPathComponent(POSIXDirectory.string($0), isDirectory: false) }
    }

    public func canonicalPath(_ url: URL) throws -> String {
        let path = url.path
        guard let resolved = realpath(path, nil) else {
            throw FileSystemError.from(errno: errno, path: path)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: DiskUsage

    public func measure(_ url: URL, options: MeasureOptions, onProgress: ((Int, String) -> Void)?) -> DiskUsage {
        var m = DiskUsage()
        let rootPath = url.path
        var st = stat()
        guard lstat(rootPath, &st) == 0 else {
            if errno == EACCES || errno == EPERM { m.permissionDeniedCount += 1 } else { m.otherErrorCount += 1 }
            return m
        }
        let rootInfo = FileInfo(url: url, stat: st)
        m.newestModification = rootInfo.modificationDate
        switch rootInfo.type {
        case .symlink:
            m.symlinkCount = 1
            m.allocatedBytes = rootInfo.allocatedSize
            return m
        case .regular, .other:
            m.fileCount = 1
            m.allocatedBytes = rootInfo.allocatedSize
            m.logicalBytes = rootInfo.logicalSize
            return m
        case .directory:
            m.allocatedBytes = rootInfo.allocatedSize
        }

        let rootDevice = rootInfo.identity.device
        var seenHardLinks = Set<FileIdentity>()
        var stack: [(path: String, relative: String, depth: Int)] = [(rootPath, "", 0)]
        var entriesVisited = 0
        var entriesSinceReport = 0

        while let (dirPath, relative, depth) = stack.popLast() {
            if Task.isCancelled {
                m.cancelled = true
                break
            }
            let fd = open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                if errno == EACCES || errno == EPERM { m.permissionDeniedCount += 1 } else if errno != ENOENT { m.otherErrorCount += 1 }
                continue
            }
            let names: [[CChar]]
            do {
                names = try POSIXDirectory.entryNames(directoryFD: fd, path: dirPath)
            } catch let error as FileSystemError {
                close(fd)
                if error.isPermissionError { m.permissionDeniedCount += 1 } else { m.otherErrorCount += 1 }
                continue
            } catch {
                close(fd)
                m.otherErrorCount += 1
                continue
            }

            for rawName in names {
                var cst = stat()
                let statResult = rawName.withUnsafeBufferPointer { fstatat(fd, $0.baseAddress!, &cst, AT_SYMLINK_NOFOLLOW) }
                let name = POSIXDirectory.string(rawName)
                let childRelative = relative.isEmpty ? name : relative + "/" + name
                if statResult != 0 {
                    if errno == EACCES || errno == EPERM { m.permissionDeniedCount += 1 } else if errno != ENOENT { m.otherErrorCount += 1 }
                    continue
                }
                entriesVisited += 1
                entriesSinceReport += 1
                let child = FileInfo(url: URL(fileURLWithPath: dirPath + "/" + name), stat: cst)
                if let newest = m.newestModification {
                    if child.modificationDate > newest { m.newestModification = child.modificationDate }
                } else {
                    m.newestModification = child.modificationDate
                }
                if options.detectSensitiveNames,
                   m.sensitiveMatches.count < Self.maxSensitiveMatches,
                   SensitiveNames.isSensitive(name: name, isDirectory: child.isDirectory) {
                    m.sensitiveMatches.append(childRelative)
                }

                switch child.type {
                case .directory:
                    if child.identity.device != rootDevice {
                        m.skippedOtherVolumeCount += 1
                        continue
                    }
                    m.directoryCount += 1
                    m.allocatedBytes += child.allocatedSize
                    if depth + 1 < options.maxDepth {
                        stack.append((dirPath + "/" + name, childRelative, depth + 1))
                    } else {
                        m.truncated = true
                    }
                case .symlink:
                    m.symlinkCount += 1
                    m.allocatedBytes += child.allocatedSize
                case .regular, .other:
                    if child.linkCount > 1 {
                        // Count hard-linked files once.
                        if !seenHardLinks.insert(child.identity).inserted { continue }
                    }
                    m.fileCount += 1
                    m.allocatedBytes += child.allocatedSize
                    m.logicalBytes += child.logicalSize
                }
            }
            close(fd)

            if entriesSinceReport >= 256 {
                onProgress?(entriesSinceReport, dirPath)
                entriesSinceReport = 0
            }
            if entriesVisited >= options.maxEntries {
                m.truncated = true
                break
            }
        }
        if entriesSinceReport > 0 {
            onProgress?(entriesSinceReport, rootPath)
        }
        return m
    }

    // MARK: Removal

    public func removeItem(_ target: ValidatedPath, expectedIdentity: FileIdentity?) throws -> RemovalReport {
        let (parentFD, name) = try openParent(of: target)
        defer { close(parentFD) }

        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileSystemError.from(errno: errno, path: target.path)
        }
        let current = FileInfo(url: target.url, stat: st)
        if let expectedIdentity, expectedIdentity != current.identity {
            throw FileSystemError.identityChanged(target.path)
        }

        var report = RemovalReport()
        switch current.type {
        case .symlink:
            throw FileSystemError.symlinkRefused(target.path)
        case .directory:
            let rawName = Array(name.utf8CString)
            removeContents(
                parentFD: parentFD,
                name: rawName,
                relative: target.components.last ?? name,
                device: current.identity.device,
                depth: 0,
                report: &report
            )
            if unlinkat(parentFD, name, AT_REMOVEDIR) == 0 {
                report.removedEntries += 1
                report.itemRemoved = true
            } else if errno == ENOENT {
                report.itemRemoved = true
            } else {
                record(&report, relative: target.components.last ?? name, errno: errno)
            }
        case .regular, .other:
            guard unlinkat(parentFD, name, 0) == 0 else {
                throw FileSystemError.from(errno: errno, path: target.path)
            }
            report.removedEntries = 1
            report.itemRemoved = true
        }
        return report
    }

    public func moveToTrash(_ target: ValidatedPath, expectedIdentity: FileIdentity?) throws {
        #if os(macOS)
        // Confirm the parent chain is still confined before handing off to FileManager.
        let (parentFD, name) = try openParent(of: target)
        defer { close(parentFD) }
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileSystemError.from(errno: errno, path: target.path)
        }
        let current = FileInfo(url: target.url, stat: st)
        if current.isSymlink { throw FileSystemError.symlinkRefused(target.path) }
        if let expectedIdentity, expectedIdentity != current.identity {
            throw FileSystemError.identityChanged(target.path)
        }
        do {
            try FileManager.default.trashItem(at: target.url, resultingItemURL: nil)
        } catch {
            throw FileSystemError.io(code: 0, path: target.path, message: "Couldn't move to Trash: \(error.localizedDescription)")
        }
        #else
        throw FileSystemError.unsupported("Moving items to the Trash")
        #endif
    }

    /// Opens the parent directory of `target` by walking down from the canonical
    /// root with `O_NOFOLLOW` on every component. Returns the parent fd and item name.
    private func openParent(of target: ValidatedPath) throws -> (Int32, String) {
        guard let name = target.components.last, !target.components.isEmpty else {
            throw FileSystemError.invalidPath(target.path)
        }
        var fd = try POSIXDirectory.openDirectory(atFD: AT_FDCWD, target.rootPath, reportedPath: target.rootPath)
        for component in target.components.dropLast() {
            let next: Int32
            do {
                next = try POSIXDirectory.openDirectory(atFD: fd, component, reportedPath: target.path)
            } catch {
                close(fd)
                throw error
            }
            close(fd)
            fd = next
        }
        return (fd, name)
    }

    private func removeContents(
        parentFD: Int32,
        name: [CChar],
        relative: String,
        device: UInt64,
        depth: Int,
        report: inout RemovalReport
    ) {
        guard depth < Self.maxRemovalDepth else {
            appendFailure(&report, "\(relative): nested too deeply")
            return
        }
        let fd = name.withUnsafeBufferPointer { openat(parentFD, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            if errno != ENOENT { record(&report, relative: relative, errno: errno) }
            return
        }
        defer { close(fd) }

        var dst = stat()
        guard fstat(fd, &dst) == 0 else {
            record(&report, relative: relative, errno: errno)
            return
        }
        guard FileInfo.device(of: dst) == device else {
            appendFailure(&report, "\(relative): on a different volume, skipped")
            return
        }

        let children: [[CChar]]
        do {
            children = try POSIXDirectory.entryNames(directoryFD: fd, path: relative)
        } catch {
            appendFailure(&report, "\(relative): \(error)")
            return
        }

        for child in children {
            let childName = POSIXDirectory.string(child)
            let childRelative = relative + "/" + childName
            var cst = stat()
            let statResult = child.withUnsafeBufferPointer { fstatat(fd, $0.baseAddress!, &cst, AT_SYMLINK_NOFOLLOW) }
            if statResult != 0 {
                if errno != ENOENT { record(&report, relative: childRelative, errno: errno) }
                continue
            }
            let mode = UInt32(cst.st_mode) & POSIXDirectory.typeMask
            if mode == POSIXDirectory.directoryType {
                if FileInfo.device(of: cst) != device {
                    appendFailure(&report, "\(childRelative): on a different volume, skipped")
                    continue
                }
                removeContents(parentFD: fd, name: child, relative: childRelative, device: device, depth: depth + 1, report: &report)
                let result = child.withUnsafeBufferPointer { unlinkat(fd, $0.baseAddress!, AT_REMOVEDIR) }
                if result == 0 {
                    report.removedEntries += 1
                } else if errno != ENOENT && errno != ENOTEMPTY && errno != EEXIST {
                    // ENOTEMPTY means a child failed and was already recorded.
                    record(&report, relative: childRelative, errno: errno)
                }
            } else {
                // Regular files, other file types, and symlinks. For a symlink,
                // unlinkat removes only the link itself, never its target.
                let result = child.withUnsafeBufferPointer { unlinkat(fd, $0.baseAddress!, 0) }
                if result == 0 {
                    report.removedEntries += 1
                } else if errno != ENOENT {
                    record(&report, relative: childRelative, errno: errno)
                }
            }
        }
    }

    private func record(_ report: inout RemovalReport, relative: String, errno code: Int32) {
        appendFailure(&report, "\(relative): \(String(cString: strerror(code)))")
    }

    private func appendFailure(_ report: inout RemovalReport, _ message: String) {
        if report.failures.count < Self.maxRecordedFailures {
            report.failures.append(message)
        } else if report.failures.count == Self.maxRecordedFailures {
            report.failures.append("…and more")
        }
    }
}

// MARK: - POSIX helpers

enum POSIXDirectory {
    static let typeMask: UInt32 = 0o170000
    static let directoryType: UInt32 = 0o040000
    static let regularType: UInt32 = 0o100000
    static let symlinkType: UInt32 = 0o120000

    /// Opens a directory relative to `parentFD` with `O_NOFOLLOW`. A symlink in the
    /// final position is reported as `.symlinkRefused` (kernels differ on whether
    /// they return ELOOP or ENOTDIR for this case, so it is checked explicitly).
    static func openDirectory(atFD parentFD: Int32, _ name: String, reportedPath: String) throws -> Int32 {
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { return fd }
        let savedErrno = errno
        if savedErrno == ELOOP || savedErrno == ENOTDIR {
            var st = stat()
            if fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
               UInt32(st.st_mode) & typeMask == symlinkType {
                throw FileSystemError.symlinkRefused(reportedPath)
            }
        }
        throw FileSystemError.from(errno: savedErrno, path: reportedPath)
    }

    /// Reads every entry name (excluding `.` and `..`) as a NUL-terminated byte array.
    /// Raw bytes are kept so that names are passed back to the kernel unchanged.
    static func entryNames(directoryFD fd: Int32, path: String) throws -> [[CChar]] {
        let dupFD = dup(fd)
        guard dupFD >= 0 else { throw FileSystemError.from(errno: errno, path: path) }
        guard let dir = fdopendir(dupFD) else {
            let code = errno
            close(dupFD)
            throw FileSystemError.from(errno: code, path: path)
        }
        defer { closedir(dir) }
        var names: [[CChar]] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw FileSystemError.from(errno: errno, path: path) }
                break
            }
            let name: [CChar] = withUnsafePointer(to: entry.pointee.d_name) { tuplePointer in
                let cString = UnsafeRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                return Array(UnsafeBufferPointer(start: cString, count: strlen(cString) + 1))
            }
            if isDotOrDotDot(name) { continue }
            names.append(name)
        }
        return names
    }

    static func isDotOrDotDot(_ name: [CChar]) -> Bool {
        (name.count == 2 && name[0] == 46) || (name.count == 3 && name[0] == 46 && name[1] == 46)
    }

    static func string(_ name: [CChar]) -> String {
        name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

extension FileInfo {
    init(url: URL, stat st: stat) {
        let mode = UInt32(st.st_mode) & POSIXDirectory.typeMask
        let type: FileType
        switch mode {
        case POSIXDirectory.directoryType: type = .directory
        case POSIXDirectory.regularType: type = .regular
        case POSIXDirectory.symlinkType: type = .symlink
        default: type = .other
        }
        #if canImport(Darwin)
        let ts = st.st_mtimespec
        let dataless = (st.st_flags & 0x4000_0000) != 0 // SF_DATALESS
        #else
        let ts = st.st_mtim
        let dataless = false
        #endif
        self.init(
            url: url,
            type: type,
            logicalSize: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000),
            identity: FileIdentity(device: FileInfo.device(of: st), inode: UInt64(st.st_ino)),
            ownerUID: UInt32(st.st_uid),
            linkCount: UInt64(st.st_nlink),
            isDataless: dataless
        )
    }

    static func device(of st: stat) -> UInt64 {
        #if canImport(Darwin)
        return UInt64(UInt32(bitPattern: st.st_dev))
        #else
        return UInt64(st.st_dev)
        #endif
    }
}

extension FileSystemError {
    static func from(errno code: Int32, path: String) -> FileSystemError {
        switch code {
        case ENOENT: return .notFound(path)
        case EACCES, EPERM: return .permissionDenied(path)
        case ENOTDIR: return .notADirectory(path)
        case ELOOP: return .symlinkRefused(path)
        default:
            return .io(code: code, path: path, message: String(cString: strerror(code)))
        }
    }
}
