import Foundation
import UpkeepCore

/// A developer folder the user explicitly approved for `__pycache__` scanning.
/// Stored as a bookmark so access survives renames and relaunches.
struct DeveloperFolder: Codable, Identifiable, Hashable {
    let id: UUID
    var path: String
    var bookmark: Data

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Persists `UpkeepSettings` and approved folders in UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    private static let settingsKey = "UpkeepSettings.v1"
    private static let foldersKey = "UpkeepDeveloperFolders.v1"

    @Published var settings: UpkeepSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    @Published private(set) var developerFolders: [DeveloperFolder]

    /// URLs we started security-scoped access for (kept open for the app's lifetime).
    private var accessedURLs: [URL] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.loadSettings(from: defaults)
        if let data = defaults.data(forKey: Self.foldersKey),
           let folders = try? JSONDecoder().decode([DeveloperFolder].self, from: data) {
            self.developerFolders = folders
        } else {
            self.developerFolders = []
        }
        resolveBookmarks()
    }

    /// Reads settings without an instance (used by the app delegate).
    nonisolated static func loadSettings(from defaults: UserDefaults = .standard) -> UpkeepSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(UpkeepSettings.self, from: data) else {
            return UpkeepSettings()
        }
        return settings.normalized()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings.normalized()) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(developerFolders) {
            defaults.set(data, forKey: Self.foldersKey)
        }
    }

    // MARK: Developer folders

    enum FolderError: LocalizedError {
        case tooBroad(String)
        case duplicate
        case bookmarkFailed(String)

        var errorDescription: String? {
            switch self {
            case .tooBroad(let path): return "“\(path)” is too broad. Choose a specific projects folder instead."
            case .duplicate: return "That folder is already in the list."
            case .bookmarkFailed(let message): return "Couldn't remember access to the folder: \(message)"
            }
        }
    }

    func addDeveloperFolder(_ url: URL) throws {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = standardized.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let tooBroad = ["/", home, home + "/Library", "/Users", "/System", "/Library", "/Applications", "/Volumes"]
        if tooBroad.contains(path) { throw FolderError.tooBroad(path) }
        if developerFolders.contains(where: { $0.path == path }) { throw FolderError.duplicate }

        let bookmark: Data
        do {
            bookmark = try standardized.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            // Non-sandboxed builds may not support security scope; a plain bookmark still tracks moves.
            do {
                bookmark = try standardized.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                throw FolderError.bookmarkFailed(error.localizedDescription)
            }
        }
        developerFolders.append(DeveloperFolder(id: UUID(), path: path, bookmark: bookmark))
        startAccessing(standardized)
        saveFolders()
        UpkeepLog.permissions.info("Developer folder added", path: path)
    }

    func removeDeveloperFolder(_ folder: DeveloperFolder) {
        developerFolders.removeAll { $0.id == folder.id }
        if let index = accessedURLs.firstIndex(where: { $0.path == folder.path }) {
            accessedURLs[index].stopAccessingSecurityScopedResource()
            accessedURLs.remove(at: index)
        }
        saveFolders()
    }

    /// Folders that currently resolve to an existing directory.
    var developerFolderURLs: [URL] {
        developerFolders.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func resolveBookmarks() {
        var changed = false
        for index in developerFolders.indices {
            var stale = false
            let bookmark = developerFolders[index].bookmark
            let resolved = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
            guard let url = resolved else { continue }
            startAccessing(url)
            if url.path != developerFolders[index].path {
                developerFolders[index].path = url.path
                changed = true
            }
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                developerFolders[index].bookmark = fresh
                changed = true
            }
        }
        if changed { saveFolders() }
    }

    private func startAccessing(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
        }
    }
}
