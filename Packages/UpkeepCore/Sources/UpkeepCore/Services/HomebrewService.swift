import Foundation

public struct HomebrewInstallation: Sendable, Equatable {
    public let executable: URL
    /// e.g. /opt/homebrew
    public var prefix: URL { executable.deletingLastPathComponent().deletingLastPathComponent() }
}

/// What `brew cleanup --dry-run` reported.
public struct HomebrewCleanupPreview: Sendable, Equatable {
    public enum EntryKind: String, Sendable {
        case cachedDownload
        case oldVersion
        case other
    }

    public struct Entry: Sendable, Equatable {
        public let path: String
        public let bytes: Int64
        public let kind: EntryKind
    }

    public var entries: [Entry] = []
    /// Homebrew's own "would free approximately …" figure, when printed.
    public var reportedTotalBytes: Int64?

    public var totalBytes: Int64 { reportedTotalBytes ?? entries.reduce(0) { $0 + $1.bytes } }

    public func bytes(of kind: EntryKind) -> Int64 {
        entries.filter { $0.kind == kind }.reduce(0) { $0 + $1.bytes }
    }

    public func count(of kind: EntryKind) -> Int {
        entries.filter { $0.kind == kind }.count
    }
}

public enum HomebrewOutputParser {
    /// Parses the output of `brew cleanup --dry-run`.
    public static func parseCleanupDryRun(_ output: String, cacheDirectory: String?) -> HomebrewCleanupPreview {
        var preview = HomebrewCleanupPreview()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "would free approximately ") {
                let rest = line[range.upperBound...]
                if let token = rest.split(separator: " ").first, let bytes = parseSize(String(token)) {
                    preview.reportedTotalBytes = bytes
                }
                continue
            }
            guard line.hasPrefix("Would remove"), let colon = line.firstIndex(of: ":") else { continue }
            var body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var bytes: Int64 = 0
            if body.hasSuffix(")"), let open = body.range(of: " (", options: .backwards) {
                let inside = body[open.upperBound..<body.index(before: body.endIndex)]
                if let last = inside.split(separator: ",").last {
                    bytes = parseSize(last.trimmingCharacters(in: .whitespaces)) ?? 0
                }
                body = String(body[..<open.lowerBound])
            }
            guard body.hasPrefix("/") else { continue }
            let kind: HomebrewCleanupPreview.EntryKind
            if let cacheDirectory, body == cacheDirectory || body.hasPrefix(cacheDirectory + "/") {
                kind = .cachedDownload
            } else if body.contains("/Cellar/") || body.contains("/Caskroom/") {
                kind = .oldVersion
            } else {
                kind = .other
            }
            preview.entries.append(.init(path: body, bytes: bytes, kind: kind))
        }
        return preview
    }

    /// Parses Homebrew's human-readable sizes ("12B", "3.4KB", "64.5MB", "1.2GB").
    /// Homebrew uses binary (1024-based) multiples.
    public static func parseSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("TB", 1_099_511_627_776), ("GB", 1_073_741_824), ("MB", 1_048_576), ("KB", 1_024), ("B", 1)]
        for (suffix, multiplier) in units where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value >= 0 else { return nil }
            return Int64((value * multiplier).rounded())
        }
        return nil
    }
}

public struct HomebrewService: Sendable {
    public let locator: ToolLocator
    public let runner: ToolRunning

    public init(locator: ToolLocator, runner: ToolRunning) {
        self.locator = locator
        self.runner = runner
    }

    public func detect() -> HomebrewInstallation? {
        locator.locate(.brew).map(HomebrewInstallation.init(executable:))
    }

    private func environment(for installation: HomebrewInstallation) -> [String: String] {
        locator.toolEnvironment(for: installation.executable, extra: [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "HOMEBREW_NO_COLOR": "1",
        ])
    }

    public func cacheDirectory(_ installation: HomebrewInstallation) async -> String? {
        guard let output = try? await runner.run(
            installation.executable, arguments: ["--cache"], environment: environment(for: installation), timeout: 60
        ), output.succeeded else { return nil }
        let path = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    /// Equivalent of `brew cleanup --dry-run`: nothing is removed.
    public func previewCleanup(_ installation: HomebrewInstallation) async throws -> HomebrewCleanupPreview {
        let cache = await cacheDirectory(installation)
        let output = try await runner.run(
            installation.executable, arguments: ["cleanup", "--dry-run"], environment: environment(for: installation), timeout: 180
        )
        guard output.succeeded else {
            throw ToolError.failed(Self.failureMessage("brew cleanup --dry-run", output))
        }
        return HomebrewOutputParser.parseCleanupDryRun(output.standardOutput, cacheDirectory: cache)
    }

    public func cleanup(_ installation: HomebrewInstallation) async throws -> ToolOutput {
        let output = try await runner.run(
            installation.executable, arguments: ["cleanup"], environment: environment(for: installation), timeout: 900
        )
        guard output.succeeded else {
            throw ToolError.failed(Self.failureMessage("brew cleanup", output))
        }
        return output
    }

    static func failureMessage(_ command: String, _ output: ToolOutput) -> String {
        if output.timedOut { return "`\(command)` timed out." }
        let detail = output.standardError.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit code \(output.exitCode)"
        return "`\(command)` failed: \(detail)"
    }
}
