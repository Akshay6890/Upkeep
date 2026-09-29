import Foundation

public enum DeveloperTool: String, Sendable, CaseIterable {
    case brew
    case npm
    case yarn
    case pnpm
    case xcrun
}

/// Resolves tool executables from a fixed list of trusted locations. The user's
/// shell `PATH` is deliberately not consulted.
public struct ToolLocator: Sendable {
    public let environment: ScanEnvironment
    public let fileSystem: FileSystemService

    public init(environment: ScanEnvironment, fileSystem: FileSystemService) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    public func locate(_ tool: DeveloperTool) -> URL? {
        candidates(for: tool).first { isTrustedExecutable($0) }
    }

    func candidates(for tool: DeveloperTool) -> [URL] {
        switch tool {
        case .brew:
            return environment.homebrewExecutableCandidates
        case .xcrun:
            return [environment.xcrunURL]
        case .npm, .yarn, .pnpm:
            var dirs = environment.toolSearchDirectories
            dirs += nvmBinDirectories()
            return dirs.map { $0.appendingPathComponent(tool.rawValue) }
        }
    }

    /// `~/.nvm/versions/node/<version>/bin`, newest version first.
    func nvmBinDirectories() -> [URL] {
        let versions = environment.homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let entries = try? fileSystem.contentsOfDirectory(at: versions) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("v") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin", isDirectory: true) }
    }

    /// An executable is trusted if it (after resolving symlinks) is a regular file,
    /// executable, owned by root or the current user, and not writable by others.
    public func isTrustedExecutable(_ url: URL) -> Bool {
        guard let canonical = try? fileSystem.canonicalPath(url),
              let info = try? fileSystem.info(at: URL(fileURLWithPath: canonical)),
              info.type == .regular else {
            return false
        }
        guard info.ownerUID == 0 || info.ownerUID == environment.currentUserID else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonical),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else {
            return false
        }
        let executable = permissions & 0o111 != 0
        let writableByOthers = permissions & 0o002 != 0
        return executable && !writableByOthers
    }

    /// A minimal, predictable environment for running tools. Only non-secret
    /// values are passed; the user's full environment is not inherited.
    public func toolEnvironment(for executable: URL, extra: [String: String] = [:]) -> [String: String] {
        var path = [executable.deletingLastPathComponent().path]
        path += environment.toolSearchDirectories.map(\.path)
        path += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var env: [String: String] = [
            "HOME": environment.homeDirectory.path,
            "PATH": path.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": environment.temporaryDirectory.path,
            "NO_COLOR": "1",
            "TERM": "dumb",
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user }
        for (key, value) in extra { env[key] = value }
        return env
    }
}
