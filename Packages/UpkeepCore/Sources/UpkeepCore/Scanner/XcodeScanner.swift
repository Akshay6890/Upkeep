import Foundation

/// Xcode DerivedData (Safe), archives, device support files, simulator caches and
/// unavailable simulators (all Review).
public struct XcodeScanner: CleanupScanner {
    public let category = CleanupCategory.xcode

    public init() {}

    public static func isDeveloperToolingPresent(_ environment: ScanEnvironment, fileSystem: FileSystemService) -> Bool {
        fileSystem.exists(environment.xcodeDeveloper)
            || fileSystem.exists(environment.coreSimulator)
            || environment.xcodeApplicationCandidates.contains { fileSystem.exists($0) }
    }

    public func scan(_ context: ScanContext) async -> CategoryResult {
        let env = context.environment
        let fs = context.fileSystem
        guard Self.isDeveloperToolingPresent(env, fileSystem: fs) else {
            return .unavailable(category, reason: "Xcode is not installed.")
        }
        var issues = ScanSupport.IssueCollector(category: category)
        var items: [CleanupItem] = []

        if fs.exists(env.derivedData) {
            items += ScanSupport.scanChildren(
                of: ApprovedRoot(kind: .derivedData, url: env.derivedData),
                rule: RuleBook.rule(for: .xcodeDerivedData), context: context, issues: &issues
            )
        }

        if fs.exists(env.xcodeArchives) {
            let root = ApprovedRoot(kind: .xcodeArchives, url: env.xcodeArchives)
            let rule = RuleBook.rule(for: .xcodeArchive)
            let dateFolders = (try? fs.contentsOfDirectory(at: env.xcodeArchives)) ?? []
            for folder in dateFolders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let info = try? fs.info(at: folder), info.isDirectory else { continue }
                items += ScanSupport.scanChildren(
                    of: root, directory: folder, parentComponents: [folder.lastPathComponent],
                    rule: rule, context: context, issues: &issues
                )
            }
        }

        for directory in env.deviceSupportDirectories where fs.exists(directory) {
            items += ScanSupport.scanChildren(
                of: ApprovedRoot(kind: .deviceSupport, url: directory),
                rule: RuleBook.rule(for: .xcodeDeviceSupport), context: context, issues: &issues
            )
        }

        if fs.exists(env.simulatorCaches) {
            items += ScanSupport.scanChildren(
                of: ApprovedRoot(kind: .simulatorCaches, url: env.simulatorCaches),
                rule: RuleBook.rule(for: .simulatorCaches), context: context, issues: &issues
            )
        }

        let simulators = SimulatorService(locator: context.toolLocator, runner: context.toolRunner)
        if simulators.isAvailable() {
            do {
                items += try await unavailableSimulatorItems(simulators, context: context)
            } catch {
                issues.issues.append(ScanIssue(
                    category: category, kind: .toolFailed, path: nil,
                    message: "Couldn't list simulators: \(error)"
                ))
            }
        }

        return CategoryResult(category: category, items: items, issues: issues.finish())
    }

    private func unavailableSimulatorItems(_ service: SimulatorService, context: ScanContext) async throws -> [CleanupItem] {
        let fs = context.fileSystem
        let devicesRoot = context.environment.simulatorDevices
        var items: [CleanupItem] = []
        for (runtime, device) in try await service.listDevices() where !device.isAvailable {
            guard SimctlParser.isValidUDID(device.udid) else { continue }
            let deviceDirectory = devicesRoot.appendingPathComponent(device.udid, isDirectory: true)
            let info = try? fs.info(at: deviceDirectory)
            let measurement = info.map { _ in fs.measure(deviceDirectory) }
            var notes = ["Runtime: \(SimctlParser.runtimeDisplayName(runtime))"]
            if let error = device.availabilityError, !error.isEmpty { notes.append(error) }
            notes.append("Removed with `xcrun simctl delete`, not by deleting files directly.")
            let item = CleanupItem(
                name: "\(device.name) (\(SimctlParser.runtimeDisplayName(runtime)))",
                url: deviceDirectory,
                category: category,
                risk: .review,
                ruleID: .unavailableSimulator,
                reason: "Simulator whose runtime is no longer installed. It can't be booted.",
                source: context.environment.displayPath(devicesRoot),
                rootURL: nil,
                method: .tool(.simctlDeleteDevice(udid: device.udid)),
                size: measurement?.allocatedBytes ?? 0,
                fileCount: measurement?.fileCount ?? 0,
                modifiedDate: measurement?.newestModification,
                identity: nil,
                notes: notes
            )
            context.progress.analyzed(item.fileCount, path: deviceDirectory.path)
            context.progress.discovered(bytes: item.size)
            items.append(item)
        }
        return items
    }
}
