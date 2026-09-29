import Foundation

/// The complete, closed set of cleanup rules.
public enum RuleBook {
    public static func rule(for id: CleanupRuleID) -> CleanupRule {
        switch id {
        case .applicationCache: return applicationCache
        case .userLog: return userLog
        case .crashReport: return crashReport
        case .trashItem: return trashItem
        case .staleTemporaryItem: return staleTemporaryItem
        case .xcodeDerivedData: return xcodeDerivedData
        case .xcodeArchive: return xcodeArchive
        case .xcodeDeviceSupport: return xcodeDeviceSupport
        case .simulatorCaches: return simulatorCaches
        case .unavailableSimulator: return unavailableSimulator
        case .homebrewCleanup: return homebrewCleanup
        case .swiftPMCache: return swiftPMCache
        case .npmCache: return npmCache
        case .yarnCache: return yarnCache
        case .pnpmStore: return pnpmStore
        case .pipCache: return pipCache
        case .pythonBytecode: return pythonBytecode
        case .largeFile: return largeFile
        }
    }

    // MARK: Application caches

    /// Folders in ~/Library/Caches that belong to a more specific scanner.
    static let claimedCacheNames: [String: String] = [
        "org.swift.swiftpm": "Swift Package Manager",
        "Yarn": "Node Package Managers",
        "pip": "Python Caches",
    ]

    /// Cache folders used by system services where removal can disrupt sync,
    /// in-progress downloads or security state. Never cleaned.
    static let protectedCacheNames: Set<String> = [
        "CloudKit", "Metadata", "FamilyCircle", "GeoServices",
        "com.apple.bird", "com.apple.cloudd", "com.apple.CloudDocs", "com.apple.iCloudHelper",
        "com.apple.nsurlsessiond", "com.apple.containermanagerd", "com.apple.akd",
        "com.apple.ap.adprivacyd", "com.apple.passd", "com.apple.homed", "com.apple.HomeKit",
        "com.apple.findmy.fmipcore", "com.apple.icloud.fmfd", "com.apple.photoanalysisd",
        "com.apple.mediaanalysisd", "com.apple.appstoreagent", "com.apple.commerce",
        "com.apple.accountsd", "com.apple.security", "com.apple.trustd", "com.apple.nbagent",
        "com.apple.cache_delete", "com.apple.keychainsharingmessagingd", "com.apple.sharingd",
        "PassKit", "Animoji", "askpermissiond",
    ]

    /// Prefixes for system services tied to iCloud, accounts, sign-in or security.
    static let protectedCachePrefixes = [
        "com.apple.icloud", "com.apple.cloud", "com.apple.bird", "com.apple.security",
        "com.apple.AuthenticationServices", "com.apple.appleaccount", "com.apple.amsaccount",
        "com.apple.dataaccess", "com.apple.Passwords", "com.apple.keychain",
    ]

    /// Apple *apps* (not background services) whose caches are ordinary app caches.
    static let appleAppCaches: Set<String> = [
        "com.apple.Safari", "com.apple.dt.Xcode", "com.apple.dt.xcodebuild", "com.apple.dt.instruments",
        "com.apple.Music", "com.apple.TV", "com.apple.podcasts", "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers", "com.apple.iWork.Keynote", "com.apple.iMovieApp", "com.apple.garageband10",
        "com.apple.helpd", "com.apple.Preview", "com.apple.QuickTimePlayerX", "com.apple.AppStore",
    ]

    /// Well-known cache folders whose names are not bundle identifiers.
    static let knownVendorCaches: [String: (risk: CleanupRisk, owner: String)] = [
        "Google": (.safe, "Google apps (Chrome, Drive)"),
        "Firefox": (.safe, "Firefox"),
        "Mozilla": (.safe, "Mozilla apps"),
        "JetBrains": (.safe, "JetBrains IDEs"),
        "Microsoft Edge": (.safe, "Microsoft Edge"),
        "BraveSoftware": (.safe, "Brave"),
        "go-build": (.safe, "the Go build cache"),
        "CocoaPods": (.safe, "CocoaPods"),
        "pypoetry": (.safe, "Poetry"),
        "typescript": (.safe, "TypeScript"),
        "deno": (.safe, "Deno"),
        "node-gyp": (.safe, "node-gyp"),
        "electron": (.safe, "Electron downloads"),
        "electron-builder": (.safe, "electron-builder"),
        "ms-playwright": (.review, "Playwright browser downloads (re-downloaded by `playwright install`)"),
        "Cypress": (.review, "the Cypress binary (re-downloaded by `cypress install`)"),
        "bazelisk": (.safe, "Bazelisk's downloaded Bazel versions"),
        "bazel": (.review, "Bazel (repository and build caches; the next build will be slower)"),
    ]

    static let commonTopLevelDomains: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "co", "me", "de", "uk", "jp", "us", "ai", "so", "sh",
        "tv", "fm", "cc", "ch", "fr", "nl", "se", "is", "it", "es", "ru", "cn", "ca", "au", "at", "eu",
    ]

    /// Whether `name` looks like a reverse-DNS bundle identifier (e.g. `com.example.App`).
    public static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, name.count <= 255 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        let first = String(parts[0])
        guard first == first.lowercased(), first.allSatisfy(\.isLetter), (2...12).contains(first.count) else { return false }
        return parts.count >= 3 || commonTopLevelDomains.contains(first)
    }

    static let applicationCache = CleanupRule(
        id: .applicationCache,
        category: .applicationCaches,
        rootKinds: [.caches],
        allowedMethods: [.delete]
    ) { candidate, context in
        guard candidate.depth == 1 else { return .ignore(reason: "Only top-level cache folders are considered.") }
        guard candidate.info.isDirectory else { return .ignore(reason: "Loose files in Caches are left alone.") }
        let name = candidate.name

        if name == "Homebrew" {
            if context.homebrewInstalled {
                return .ignore(reason: "Handled by the Homebrew category using `brew cleanup`.")
            }
            return .candidate(risk: .safe, reason: "Homebrew is not installed; this is a leftover download cache.", notes: [])
        }
        if let owner = claimedCacheNames[name] {
            return .ignore(reason: "Handled by the \(owner) category.")
        }
        if protectedCacheNames.contains(name) || protectedCachePrefixes.contains(where: { name.hasPrefix($0) }) {
            return .protected(reason: "Used by a system or iCloud service. Removing it can interrupt sync or downloads.")
        }
        if let vendor = knownVendorCaches[name] {
            return .candidate(risk: vendor.risk, reason: "Cache for \(vendor.owner). It is recreated when needed.", notes: [])
        }
        guard looksLikeBundleIdentifier(name) else {
            return .protected(reason: "Upkeep couldn't confidently identify the app that owns this folder.")
        }
        if name.hasPrefix("com.apple.") && !appleAppCaches.contains(name) {
            // Background macOS services rebuild these, but they're usually small and
            // removing them gains little, so they're never pre-selected.
            return .candidate(
                risk: .review,
                reason: "Cache for the macOS service \(name). macOS rebuilds it, but removing it rarely frees much space.",
                notes: []
            )
        }
        if context.runningBundleIdentifiers.contains(name) {
            return .candidate(
                risk: .review,
                reason: "Cache for \(name). Apps recreate their caches when needed.",
                notes: ["This app is running. Quit it before cleaning so it doesn't rebuild the cache immediately."]
            )
        }
        return .candidate(risk: .safe, reason: "Cache for \(name). Apps recreate their caches when needed.", notes: [])
    }

    // MARK: Logs and crash reports

    static let userLog = CleanupRule(
        id: .userLog,
        category: .logs,
        rootKinds: [.logs],
        allowedMethods: [.delete],
        needsMeasurement: false
    ) { candidate, context in
        guard candidate.relativeComponents.first != "DiagnosticReports" else {
            return .ignore(reason: "Handled by the Crash Reports category.")
        }
        guard candidate.info.type == .regular else { return .ignore(reason: "Only regular files are considered.") }
        guard candidate.info.ownerUID == context.currentUserID else { return .ignore(reason: "Not owned by you.") }
        let minimum = context.settings.logMinimumAgeDays
        let age = context.ageInDays(candidate.info.modificationDate)
        guard age >= Double(minimum) else { return .ignore(reason: "Modified within the last \(minimum) days.") }
        return .candidate(risk: .safe, reason: "Log file not modified for \(Int(age)) days.", notes: [])
    }

    static let crashReportExtensions: Set<String> = ["ips", "crash", "diag", "spin", "hang", "panic", "shutdownstall", "cpu_resource"]

    static let crashReport = CleanupRule(
        id: .crashReport,
        category: .crashReports,
        rootKinds: [.diagnosticReports],
        allowedMethods: [.delete],
        needsMeasurement: false
    ) { candidate, context in
        guard candidate.depth <= 2 else { return .ignore(reason: "Nested too deeply.") }
        guard candidate.info.type == .regular else { return .ignore(reason: "Only report files are considered.") }
        guard candidate.info.ownerUID == context.currentUserID else { return .ignore(reason: "Not owned by you.") }
        let ext = candidate.url.pathExtension.lowercased()
        guard crashReportExtensions.contains(ext) else { return .ignore(reason: "Not a diagnostic report.") }
        let minimum = context.settings.crashReportMinimumAgeDays
        let age = context.ageInDays(candidate.info.modificationDate)
        guard age >= Double(minimum) else { return .ignore(reason: "Created within the last \(minimum) days.") }
        return .candidate(risk: .safe, reason: "Diagnostic report from \(Int(age)) days ago.", notes: [])
    }

    /// Extracts the application name from a report file name such as
    /// `Safari-2024-05-01-101010.ips` or `Xcode_2024-05-01-101010_Mac.diag`.
    public static func applicationName(fromReportName fileName: String) -> String {
        var base = fileName
        if let dot = base.lastIndex(of: ".") { base = String(base[..<dot]) }
        let characters = Array(base)
        // Find the first "YYYY-" date that is preceded by "-" or "_".
        var index = 1
        while index + 4 < characters.count {
            let separator = characters[index - 1]
            if separator == "-" || separator == "_",
               characters[index..<index + 4].allSatisfy(\.isNumber),
               characters[index + 4] == "-" {
                let name = String(characters[0..<(index - 1)])
                return name.isEmpty ? base : name
            }
            index += 1
        }
        return base
    }

    // MARK: Trash

    static let trashItem = CleanupRule(
        id: .trashItem,
        category: .trash,
        rootKinds: [.trash],
        allowedMethods: [.deletePermanently],
        sensitiveHandling: .note
    ) { candidate, _ in
        guard candidate.depth == 1 else { return .ignore(reason: "Only top-level Trash items are considered.") }
        guard candidate.name != ".DS_Store" else { return .ignore(reason: "Finder metadata.") }
        guard candidate.info.type == .regular || candidate.info.type == .directory else {
            return .ignore(reason: "Unsupported item type.")
        }
        return .candidate(risk: .review, reason: "In your Trash. Deleting it is permanent.", notes: [])
    }

    // MARK: Temporary files

    static let staleTemporaryItem = CleanupRule(
        id: .staleTemporaryItem,
        category: .temporaryFiles,
        rootKinds: [.temporary],
        allowedMethods: [.delete]
    ) { candidate, context in
        guard candidate.depth == 1 else { return .ignore(reason: "Only top-level temporary items are considered.") }
        guard candidate.info.type == .regular || candidate.info.type == .directory else {
            return .ignore(reason: "Sockets and other special files are left alone.")
        }
        guard candidate.info.ownerUID == context.currentUserID else { return .ignore(reason: "Not owned by you.") }
        guard !candidate.name.hasPrefix("com.apple.") else {
            return .ignore(reason: "Managed by macOS.")
        }
        let minimum = context.settings.temporaryFileMinimumAgeDays
        let age = context.ageInDays(candidate.newestModification)
        guard age >= Double(minimum) else { return .ignore(reason: "Modified within the last \(minimum) days.") }
        return .candidate(risk: .safe, reason: "Temporary item untouched for \(Int(age)) days.", notes: [])
    }

    // MARK: Xcode

    static let xcodeBundleIdentifier = "com.apple.dt.Xcode"

    static let xcodeDerivedData = CleanupRule(
        id: .xcodeDerivedData,
        category: .xcode,
        rootKinds: [.derivedData],
        allowedMethods: [.delete],
        // DerivedData/…/SourcePackages/checkouts holds Git clones of package dependencies,
        // which Xcode re-fetches. They are not the user's repositories.
        sensitiveHandling: .allow
    ) { candidate, context in
        guard candidate.depth == 1, candidate.info.isDirectory else { return .ignore(reason: "Only project folders are considered.") }
        if context.runningBundleIdentifiers.contains(xcodeBundleIdentifier) {
            return .candidate(
                risk: .review,
                reason: "Build products and indexes. Xcode rebuilds them automatically.",
                notes: ["Xcode is running. Quit Xcode before cleaning to avoid build errors."]
            )
        }
        return .candidate(risk: .safe, reason: "Build products and indexes. Xcode rebuilds them automatically.", notes: [])
    }

    static let xcodeArchive = CleanupRule(
        id: .xcodeArchive,
        category: .xcode,
        rootKinds: [.xcodeArchives],
        allowedMethods: [.delete]
    ) { candidate, _ in
        guard candidate.depth == 2, candidate.info.isDirectory, candidate.url.pathExtension == "xcarchive" else {
            return .ignore(reason: "Not an Xcode archive.")
        }
        return .candidate(
            risk: .review,
            reason: "Archived build. You may need it to symbolicate crash reports or re-export this release.",
            notes: []
        )
    }

    static let xcodeDeviceSupport = CleanupRule(
        id: .xcodeDeviceSupport,
        category: .xcode,
        rootKinds: [.deviceSupport],
        allowedMethods: [.delete]
    ) { candidate, _ in
        guard candidate.depth == 1, candidate.info.isDirectory else { return .ignore(reason: "Not a device support folder.") }
        return .candidate(
            risk: .review,
            reason: "Debug symbols for a device OS version. Xcode copies them again the next time such a device connects.",
            notes: []
        )
    }

    static let simulatorCaches = CleanupRule(
        id: .simulatorCaches,
        category: .xcode,
        rootKinds: [.simulatorCaches],
        allowedMethods: [.delete]
    ) { candidate, _ in
        guard candidate.depth == 1, candidate.info.isDirectory else { return .ignore(reason: "Not a simulator cache folder.") }
        return .candidate(risk: .review, reason: "Simulator caches. Rebuilt the next time a simulator boots, which can take a while.", notes: [])
    }

    /// Tool-managed: validated by re-querying `simctl`, never by path.
    static let unavailableSimulator = CleanupRule(
        id: .unavailableSimulator,
        category: .xcode,
        rootKinds: [],
        allowedMethods: [.simctlDelete]
    ) { _, _ in
        .candidate(risk: .review, reason: "Simulator whose runtime is no longer installed.", notes: [])
    }

    // MARK: Homebrew

    static let homebrewCleanup = CleanupRule(
        id: .homebrewCleanup,
        category: .homebrew,
        rootKinds: [],
        allowedMethods: [.homebrewCleanup]
    ) { _, _ in
        .candidate(risk: .safe, reason: "Old versions and stale downloads that `brew cleanup` would remove.", notes: [])
    }

    // MARK: Package managers

    static let swiftPMCache = CleanupRule(
        id: .swiftPMCache,
        category: .swiftPackageManager,
        rootKinds: [.caches],
        allowedMethods: [.delete],
        // `repositories` holds bare Git mirrors that SwiftPM re-creates; they are
        // caches, not the user's source repositories.
        sensitiveHandling: .allow
    ) { candidate, _ in
        guard candidate.depth == 2, candidate.relativeComponents[0] == "org.swift.swiftpm", candidate.info.isDirectory else {
            return .ignore(reason: "Not part of the SwiftPM cache.")
        }
        return .candidate(risk: .safe, reason: "Shared SwiftPM download cache. Refilled on the next package resolve.", notes: [])
    }

    static let npmCacheNames: [String: String] = [
        "_cacache": "npm's package cache.",
        "_npx": "Packages downloaded by npx.",
        "_logs": "npm debug logs.",
    ]

    static let npmCache = CleanupRule(
        id: .npmCache,
        category: .nodePackageManagers,
        rootKinds: [.npm],
        allowedMethods: [.delete, .npmCacheClean]
    ) { candidate, _ in
        guard candidate.depth == 1, candidate.info.isDirectory, let description = npmCacheNames[candidate.name] else {
            return .ignore(reason: "Not an npm cache folder.")
        }
        return .candidate(risk: .safe, reason: description + " npm downloads packages again when needed.", notes: [])
    }

    static let yarnCache = CleanupRule(
        id: .yarnCache,
        category: .nodePackageManagers,
        rootKinds: [.caches, .yarnBerry],
        allowedMethods: [.delete, .yarnCacheClean]
    ) { candidate, _ in
        let isClassicCache = candidate.rootKind == .caches && candidate.name == "Yarn"
        let isBerryCache = candidate.rootKind == .yarnBerry && candidate.name == "cache"
        guard candidate.depth == 1, candidate.info.isDirectory, isClassicCache || isBerryCache else {
            return .ignore(reason: "Not a Yarn cache folder.")
        }
        return .candidate(risk: .safe, reason: "Yarn's global package cache. Yarn downloads packages again when needed.", notes: [])
    }

    static let pnpmStore = CleanupRule(
        id: .pnpmStore,
        category: .nodePackageManagers,
        rootKinds: [.pnpmHome],
        allowedMethods: [.pnpmStorePrune, .revealOnly]
    ) { candidate, _ in
        guard candidate.depth == 1, candidate.info.isDirectory, candidate.name == "store" else {
            return .ignore(reason: "Not the pnpm store.")
        }
        return .candidate(
            risk: .review,
            reason: "pnpm's content-addressable store.",
            notes: ["`pnpm store prune` removes only packages no project references, so less space than shown may be freed."]
        )
    }

    static let pipCache = CleanupRule(
        id: .pipCache,
        category: .pythonCaches,
        rootKinds: [.caches],
        allowedMethods: [.delete]
    ) { candidate, _ in
        guard candidate.depth == 1, candidate.info.isDirectory, candidate.name == "pip" else {
            return .ignore(reason: "Not the pip cache.")
        }
        return .candidate(risk: .safe, reason: "pip's download and wheel cache. pip downloads packages again when needed.", notes: [])
    }

    static let bytecodeExtensions: Set<String> = ["pyc", "pyo"]

    static let pythonBytecode = CleanupRule(
        id: .pythonBytecode,
        category: .pythonCaches,
        rootKinds: [.developerFolder],
        allowedMethods: [.delete],
        needsChildNames: true
    ) { candidate, _ in
        guard candidate.name == "__pycache__", candidate.info.isDirectory else {
            return .ignore(reason: "Not a __pycache__ folder.")
        }
        guard let children = candidate.childNames else {
            return .ignore(reason: "Contents unknown.")
        }
        // The measurement is absent only during the scanner's cheap first pass.
        if let measurement = candidate.measurement, measurement.directoryCount > 0 || measurement.symlinkCount > 0 {
            return .protected(reason: "Contains more than compiled bytecode.")
        }
        let onlyBytecode = children.allSatisfy { child in
            guard let dot = child.lastIndex(of: "."), dot != child.startIndex else { return false }
            return bytecodeExtensions.contains(child[child.index(after: dot)...].lowercased())
        }
        guard onlyBytecode else { return .protected(reason: "Contains files other than .pyc/.pyo bytecode.") }
        return .candidate(risk: .safe, reason: "Compiled Python bytecode. Python regenerates it on the next run.", notes: [])
    }

    // MARK: Large files

    static let largeFile = CleanupRule(
        id: .largeFile,
        category: .largeFiles,
        rootKinds: [],
        allowedMethods: [.revealOnly],
        needsMeasurement: false
    ) { _, _ in
        .candidate(risk: .review, reason: "Large file. Shown for your information; Upkeep never deletes it.", notes: [])
    }
}
