import AppKit
import UpkeepCore

/// Explains and requests access through the proper macOS mechanisms. Upkeep never
/// tries to work around privacy protections: if access is denied, the location is
/// skipped and reported.
enum PermissionService {
    enum FullDiskAccessStatus {
        case granted
        case denied
        case unknown
    }

    /// Listing ~/.Trash requires Full Disk Access on current macOS versions, and it's
    /// also the main location Upkeep needs it for, so it doubles as the check.
    static func fullDiskAccessStatus() -> FullDiskAccessStatus {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        do {
            _ = try LocalFileSystem().contentsOfDirectory(at: trash)
            return .granted
        } catch let error as FileSystemError where error.isPermissionError {
            return .denied
        } catch {
            return .unknown
        }
    }

    static func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                UpkeepLog.permissions.info("Opened Full Disk Access settings")
                return
            }
        }
    }

    /// Lets the user choose a developer folder with the standard open panel.
    @MainActor
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum FinderService {
    /// Reveals the item in Finder, or its closest existing parent if it's gone.
    static func reveal(_ url: URL) {
        var target = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: target.path) && target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    static func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }
}

enum RunningApplications {
    static func bundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

enum SystemInfo {
    /// "Apple Silicon" or "Intel", read from the hardware (correct even under Rosetta).
    static var chipDescription: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
            return "Apple Silicon"
        }
        return "Intel"
    }
}
