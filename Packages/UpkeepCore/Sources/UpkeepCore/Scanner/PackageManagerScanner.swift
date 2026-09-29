import Foundation

/// SwiftPM's shared cache in ~/Library/Caches/org.swift.swiftpm. Project-local
/// `.build` folders and ~/Library/org.swift.swiftpm (configuration and security
/// fingerprints) are never touched.
public struct SwiftPackageManagerScanner: CleanupScanner {
    public let category = CleanupCategory.swiftPackageManager

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        let env = context.environment
        guard context.fileSystem.exists(env.swiftPMCache) else {
            return .unavailable(category, reason: "No Swift Package Manager cache found.")
        }
        var issues = ScanSupport.IssueCollector(category: category)
        let items = ScanSupport.scanChildren(
            of: ApprovedRoot(kind: .caches, url: env.caches),
            directory: env.swiftPMCache,
            parentComponents: [env.swiftPMCache.lastPathComponent],
            rule: RuleBook.rule(for: .swiftPMCache), context: context, issues: &issues
        )
        return CategoryResult(category: category, items: items, issues: issues.finish())
    }
}

/// npm, Yarn and pnpm global caches. Cleaned with each tool's own command when the
/// tool is installed. `node_modules` and project folders are never scanned.
public struct NodePackageManagerScanner: CleanupScanner {
    public let category = CleanupCategory.nodePackageManagers

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        let env = context.environment
        let fs = context.fileSystem
        let yarnClassic = env.caches.appendingPathComponent("Yarn", isDirectory: true)
        let yarnBerry = env.yarnBerryDirectory.appendingPathComponent("cache", isDirectory: true)
        let pnpmStore = env.pnpmHome.appendingPathComponent("store", isDirectory: true)
        guard fs.exists(env.npmDirectory) || fs.exists(yarnClassic) || fs.exists(yarnBerry) || fs.exists(pnpmStore) else {
            return .unavailable(category, reason: "No npm, Yarn or pnpm caches found.")
        }

        var issues = ScanSupport.IssueCollector(category: category)
        var items: [CleanupItem] = []
        let locator = context.toolLocator

        if fs.exists(env.npmDirectory) {
            let npmAvailable = locator.locate(.npm) != nil
            items += ScanSupport.scanChildren(
                of: ApprovedRoot(kind: .npm, url: env.npmDirectory),
                rule: RuleBook.rule(for: .npmCache), context: context, issues: &issues,
                methodFor: { candidate in
                    candidate.name == "_cacache" && npmAvailable ? .tool(.npmCacheClean) : .delete
                }
            )
        }

        let yarnRule = RuleBook.rule(for: .yarnCache)
        if let info = try? fs.info(at: yarnClassic) {
            let yarnAvailable = locator.locate(.yarn) != nil
            if let item = ScanSupport.evaluate(
                url: yarnClassic, info: info, root: ApprovedRoot(kind: .caches, url: env.caches),
                relativeComponents: ["Yarn"], rule: yarnRule, context: context, issues: &issues,
                methodFor: { _ in yarnAvailable ? .tool(.yarnCacheClean) : .delete },
                nameFor: { _ in "Yarn cache" }
            ) {
                items.append(item)
            }
        }
        if let info = try? fs.info(at: yarnBerry) {
            if let item = ScanSupport.evaluate(
                url: yarnBerry, info: info, root: ApprovedRoot(kind: .yarnBerry, url: env.yarnBerryDirectory),
                relativeComponents: ["cache"], rule: yarnRule, context: context, issues: &issues,
                nameFor: { _ in "Yarn Berry global cache" }
            ) {
                items.append(item)
            }
        }

        if let info = try? fs.info(at: pnpmStore) {
            let pnpmAvailable = locator.locate(.pnpm) != nil
            let extraNotes = pnpmAvailable ? [] : ["pnpm isn't installed in a known location, so Upkeep can't prune this store. Run `pnpm store prune` yourself."]
            if let item = ScanSupport.evaluate(
                url: pnpmStore, info: info, root: ApprovedRoot(kind: .pnpmHome, url: env.pnpmHome),
                relativeComponents: ["store"], rule: RuleBook.rule(for: .pnpmStore), context: context, issues: &issues,
                methodFor: { _ in pnpmAvailable ? .tool(.pnpmStorePrune) : .revealOnly },
                nameFor: { _ in "pnpm store" },
                extraNotes: extraNotes
            ) {
                items.append(item)
            }
        }

        return CategoryResult(category: category, items: items, issues: issues.finish())
    }
}
