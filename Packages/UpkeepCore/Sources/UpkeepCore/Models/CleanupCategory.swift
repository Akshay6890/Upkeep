import Foundation

/// Settings groups that let users switch whole families of categories on or off.
public enum CategoryGroup: String, Codable, Sendable {
    case general
    case logs
    case developer
    case packageManagers
    case largeFiles
}

public enum CleanupCategory: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
    case applicationCaches
    case logs
    case crashReports
    case temporaryFiles
    case trash
    case xcode
    case homebrew
    case swiftPackageManager
    case nodePackageManagers
    case pythonCaches
    case largeFiles

    public var id: String { rawValue }

    public static func < (lhs: CleanupCategory, rhs: CleanupCategory) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var title: String {
        switch self {
        case .applicationCaches: return "Application Caches"
        case .logs: return "Logs"
        case .crashReports: return "Crash Reports"
        case .temporaryFiles: return "Temporary Files"
        case .trash: return "Trash"
        case .xcode: return "Xcode"
        case .homebrew: return "Homebrew"
        case .swiftPackageManager: return "Swift Package Manager"
        case .nodePackageManagers: return "Node Package Managers"
        case .pythonCaches: return "Python Caches"
        case .largeFiles: return "Large Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .applicationCaches: return "square.stack.3d.up"
        case .logs: return "doc.text"
        case .crashReports: return "exclamationmark.bubble"
        case .temporaryFiles: return "clock.arrow.circlepath"
        case .trash: return "trash"
        case .xcode: return "hammer"
        case .homebrew: return "mug"
        case .swiftPackageManager: return "shippingbox"
        case .nodePackageManagers: return "cube.box"
        case .pythonCaches: return "chevron.left.forwardslash.chevron.right"
        case .largeFiles: return "doc.badge.ellipsis"
        }
    }

    /// Human-readable explanation of what the category contains and why it is (or isn't) removable.
    public var explanation: String {
        switch self {
        case .applicationCaches:
            return "Per-app cache folders in ~/Library/Caches. Apps recreate these when needed. Folders Upkeep can't confidently attribute to an app are left alone."
        case .logs:
            return "Log files in ~/Library/Logs older than your configured age. Recent logs are kept because they can help diagnose current problems."
        case .crashReports:
            return "Old crash, hang and diagnostic reports in ~/Library/Logs/DiagnosticReports. Recent reports are kept."
        case .temporaryFiles:
            return "Items in your per-user temporary folder that you own and nothing has modified for a while. System-managed temporary storage is not touched."
        case .trash:
            return "Items already in your Trash. Removing them is permanent and cannot be undone."
        case .xcode:
            return "DerivedData is rebuilt by Xcode automatically. Archives, device support files and simulator data need review: archives may be needed to symbolicate crash reports."
        case .homebrew:
            return "Old formula versions and cached downloads, as reported and removed by Homebrew's own `brew cleanup`."
        case .swiftPackageManager:
            return "SwiftPM's shared download cache. Projects keep their own checkouts, so this cache is refilled on the next resolve."
        case .nodePackageManagers:
            return "npm, Yarn and pnpm caches. Cleaned with each tool's own command where available. node_modules folders and projects are never touched."
        case .pythonCaches:
            return "pip's download cache and __pycache__ bytecode folders inside developer folders you chose. Python regenerates both automatically."
        case .largeFiles:
            return "Files in your home folder above the size threshold. Shown for your information only; Upkeep never deletes them."
        }
    }

    public var group: CategoryGroup {
        switch self {
        case .applicationCaches, .temporaryFiles, .trash: return .general
        case .logs, .crashReports: return .logs
        case .xcode, .pythonCaches: return .developer
        case .homebrew, .swiftPackageManager, .nodePackageManagers: return .packageManagers
        case .largeFiles: return .largeFiles
        }
    }

    /// Categories that take part in the main "Scan Mac" flow. Large files are scanned separately.
    public static var cleanupCategories: [CleanupCategory] {
        allCases.filter { $0 != .largeFiles }
    }
}
