import Foundation

/// A path that passed validation: it is strictly inside an approved root, its
/// parent chain contains no symlinks leading elsewhere, and it is not protected.
public struct ValidatedPath: Hashable, Sendable {
    /// Canonical (symlink-free) path of the approved root.
    public let rootPath: String
    /// Components below the root, ending with the item's own name. Never empty.
    public let components: [String]

    public var path: String { rootPath + "/" + components.joined(separator: "/") }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// Paths that must never be removed, and user-data locations that may only be
/// touched when the user explicitly approved a folder inside them.
public struct ProtectedPaths: Sendable {
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }

    public init(homeDirectory: URL, fileSystem: FileSystemService) {
        let home = homeDirectory.path
        let userRelative = [
            "", // the home folder itself
            "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
            "Library", // the Library folder itself (its children are handled individually)
            "Library/Mobile Documents", "Library/CloudStorage", "Library/Keychains",
            "Library/Application Support", "Library/Containers", "Library/Group Containers",
            "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies",
            "Library/Preferences", "Library/Accounts", "Library/Calendars", "Library/Photos",
            "Library/Developer/Xcode/UserData", "Library/org.swift.swiftpm",
            "Library/Caches", "Library/Logs", "Library/Developer",
            ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".config",
        ]
        let system = [
            "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private",
            "/Applications", "/opt", "/cores", "/Users", "/Volumes", "/dev",
        ]
        var result: [String] = []
        for relative in userRelative {
            let raw = relative.isEmpty ? home : home + "/" + relative
            result.append(raw)
            if let canonical = try? fileSystem.canonicalPath(URL(fileURLWithPath: raw)), canonical != raw {
                result.append(canonical)
            }
        }
        for raw in system {
            result.append(raw)
            if let canonical = try? fileSystem.canonicalPath(URL(fileURLWithPath: raw)), canonical != raw {
                result.append(canonical)
            }
        }
        self.paths = Array(Set(result)).sorted()
    }

    /// Throws `.protectedPath` if removing `fullPath` (inside `rootPath`) would touch protected data.
    public func check(fullPath: String, rootPath: String, relativeComponents: [String]) throws {
        for protected in paths {
            let normalized = protected == "/" ? "" : protected
            // The item is a protected path, or contains one.
            if fullPath == protected || protected.hasPrefix(fullPath + "/") {
                throw FileSystemError.protectedPath(fullPath)
            }
            // The item is inside a protected area: only allowed when the approved
            // root itself lies inside that area (the user or a rule explicitly
            // approved that more specific location).
            if fullPath.hasPrefix(normalized + "/") {
                let rootInside = rootPath == protected || rootPath.hasPrefix(normalized + "/")
                if !rootInside {
                    throw FileSystemError.protectedPath(fullPath)
                }
            }
        }
        if SensitiveNames.containsSensitiveComponent(relativeComponents) {
            throw FileSystemError.protectedPath(fullPath)
        }
    }
}

public struct PathValidator: Sendable {
    public let fileSystem: FileSystemService
    public let protectedPaths: ProtectedPaths

    public init(fileSystem: FileSystemService, protectedPaths: ProtectedPaths) {
        self.fileSystem = fileSystem
        self.protectedPaths = protectedPaths
    }

    /// Validates that `url` may be cleaned as a child (at any depth) of `root`.
    public func validate(_ url: URL, within root: URL) throws -> ValidatedPath {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), !path.contains("\u{0}") else {
            throw FileSystemError.invalidPath(path)
        }
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !rawComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            throw FileSystemError.invalidPath(path)
        }
        let rootRaw = root.path
        guard rootRaw.hasPrefix("/"), !rootRaw.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw FileSystemError.invalidPath(rootRaw)
        }

        let rootPath = try fileSystem.canonicalPath(root)
        guard rootPath != "/" else { throw FileSystemError.protectedPath(rootPath) }

        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/", !name.contains("/") else {
            throw FileSystemError.invalidPath(path)
        }
        let parentPath: String
        do {
            parentPath = try fileSystem.canonicalPath(url.deletingLastPathComponent())
        } catch FileSystemError.notFound {
            throw FileSystemError.notFound(path)
        }
        guard parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") else {
            throw FileSystemError.outsideApprovedRoot(path)
        }
        let below = parentPath.dropFirst(rootPath.count)
        let relative = below.split(separator: "/").map(String.init) + [name]
        let fullPath = rootPath + "/" + relative.joined(separator: "/")

        try protectedPaths.check(fullPath: fullPath, rootPath: rootPath, relativeComponents: relative)
        return ValidatedPath(rootPath: rootPath, components: relative)
    }
}
