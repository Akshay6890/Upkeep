import Foundation

/// pip's download cache, plus `__pycache__` folders inside developer folders the
/// user explicitly chose. Only folders named exactly `__pycache__` that contain
/// nothing but `.pyc`/`.pyo` files qualify. Other files are never candidates.
public struct PythonCacheScanner: CleanupScanner {
    public let category = CleanupCategory.pythonCaches
    static let maxDepth = 12
    static let maxDirectoriesPerFolder = 50_000
    static let skippedDirectoryNames: Set<String> = ["node_modules", "Library", "Pods", "DerivedData"]

    public init() {}

    public func scan(_ context: ScanContext) async -> CategoryResult {
        let env = context.environment
        let fs = context.fileSystem
        let pipCache = env.caches.appendingPathComponent("pip", isDirectory: true)
        let hasPip = fs.exists(pipCache)
        guard hasPip || !env.developerFolders.isEmpty else {
            return .unavailable(category, reason: "No pip cache found and no developer folders chosen.")
        }

        var issues = ScanSupport.IssueCollector(category: category)
        var items: [CleanupItem] = []

        if hasPip, let info = try? fs.info(at: pipCache) {
            if let item = ScanSupport.evaluate(
                url: pipCache, info: info, root: ApprovedRoot(kind: .caches, url: env.caches),
                relativeComponents: ["pip"], rule: RuleBook.rule(for: .pipCache), context: context, issues: &issues,
                nameFor: { _ in "pip cache" }
            ) {
                items.append(item)
            }
        }

        let rule = RuleBook.rule(for: .pythonBytecode)
        for folder in env.developerFolders {
            guard fs.exists(folder) else {
                issues.issues.append(ScanIssue(
                    category: category, kind: .notFound, path: env.displayPath(folder),
                    message: "Developer folder \(env.displayPath(folder)) is no longer available."
                ))
                continue
            }
            let root = ApprovedRoot(kind: .developerFolder, url: folder)
            var stack: [(URL, [String])] = [(folder, [])]
            var visited = 0
            while let (directory, components) = stack.popLast(), visited < Self.maxDirectoriesPerFolder {
                if Task.isCancelled { break }
                visited += 1
                let children: [URL]
                do {
                    children = try fs.contentsOfDirectory(at: directory)
                } catch {
                    issues.record(error, path: directory.path, environment: env)
                    continue
                }
                context.progress.analyzed(children.count, path: directory.path)
                for child in children {
                    let name = child.lastPathComponent
                    guard let info = try? fs.info(at: child), info.isDirectory else { continue }
                    let childComponents = components + [name]
                    if name == "__pycache__" {
                        if let item = ScanSupport.evaluate(
                            url: child, info: info, root: root, relativeComponents: childComponents,
                            rule: rule, context: context, issues: &issues,
                            nameFor: { candidate in candidate.relativeComponents.joined(separator: "/") }
                        ) {
                            items.append(item)
                        }
                        continue
                    }
                    // Don't descend into hidden folders (.git, .venv…), bundles or dependency trees.
                    if name.hasPrefix(".") || Self.skippedDirectoryNames.contains(name) || child.pathExtension == "app" { continue }
                    if childComponents.count < Self.maxDepth { stack.append((child, childComponents)) }
                }
            }
        }
        return CategoryResult(category: category, items: items, issues: issues.finish())
    }
}
