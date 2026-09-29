import AppKit
import Combine
import SwiftUI
import UpkeepCore

enum SidebarItem: Hashable {
    case overview
    case category(CleanupCategory)
    case largeFiles
    case issues
}

enum CategorySelectionState {
    case none
    case some
    case all
}

/// Owns the app's state and coordinates the engine. All heavy work runs in
/// detached tasks; this object only publishes results on the main actor.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case cleaning
        case finished
    }

    enum ScanTrigger {
        case manual
        case scheduled
    }

    // Scan
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var scanProgress = ScanProgress()
    @Published private(set) var scanResult: ScanResult?
    @Published var selectedItemIDs: Set<String> = []

    // Storage
    @Published private(set) var storage: StorageSummary?
    @Published private(set) var storageBeforeCleanup: StorageSummary?
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var lastReclaimableBytes: Int64?

    // Cleanup
    @Published var pendingPlan: CleanupPlan?
    @Published private(set) var cleanupProgress: CleanupProgress?
    @Published private(set) var cleanupReport: CleanupReport?

    // Large files
    @Published private(set) var largeFiles: CategoryResult?
    @Published private(set) var largeFilesProgress = ScanProgress()
    @Published private(set) var isScanningLargeFiles = false

    // Permissions
    @Published private(set) var fullDiskAccess: PermissionService.FullDiskAccessStatus = .unknown

    @Published var errorMessage: String?

    // Navigation: the sidebar selection plus a history for the Back button.
    @Published private(set) var destination: SidebarItem = .overview
    private var navigationHistory: [SidebarItem] = []

    let settingsStore: SettingsStore
    private var scanWorker: Task<ScanResult, Never>?
    private var largeFilesWorker: Task<CategoryResult, Never>?
    private var cleanupWorker: Task<CleanupReport, Never>?
    private var scheduleTimer: Timer?
    private var settingsObserver: AnyCancellable?

    private static let lastScanKey = "UpkeepLastScanDate"
    private static let lastReclaimableKey = "UpkeepLastReclaimableBytes"

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let defaults = UserDefaults.standard
        lastScanDate = defaults.object(forKey: Self.lastScanKey) as? Date
        if defaults.object(forKey: Self.lastReclaimableKey) != nil {
            lastReclaimableBytes = Int64(defaults.integer(forKey: Self.lastReclaimableKey))
        }
        refreshStorage()
        refreshPermissions()
        startScheduler()
        // Views read settings through AppState, so republish settings changes.
        // Only real changes are forwarded (@Published also fires for no-op assignments).
        settingsObserver = settingsStore.$settings
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    var settings: UpkeepSettings { settingsStore.settings }

    private func makeEngine() -> CleanupEngine {
        CleanupEngine(
            environment: ScanEnvironment.current(developerFolders: settingsStore.developerFolderURLs),
            settings: settingsStore.settings,
            runningBundleIdentifiers: RunningApplications.bundleIdentifiers()
        )
    }

    // MARK: Navigation

    func navigate(to item: SidebarItem) {
        guard item != destination else { return }
        navigationHistory.append(destination)
        if navigationHistory.count > 50 { navigationHistory.removeFirst() }
        destination = item
    }

    /// Returns to the previous page, or to Overview when there is no history.
    func goBack() {
        destination = navigationHistory.popLast() ?? .overview
    }

    // MARK: Storage & permissions

    func refreshStorage() {
        do {
            let summary = try DiskSpaceService().storageSummary(for: FileManager.default.homeDirectoryForCurrentUser)
            if summary != storage { storage = summary }
        } catch {
            UpkeepLog.app.warning("Couldn't read volume capacity: \(error)")
        }
    }

    func refreshPermissions() {
        let status = PermissionService.fullDiskAccessStatus()
        if status != fullDiskAccess { fullDiskAccess = status }
    }

    // MARK: Scanning

    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    func startScan(trigger: ScanTrigger = .manual) {
        guard !isBusy else { return }
        refreshPermissions()
        let previousSelection = selectedItemIDs
        let previousItemIDs = Set(scanResult?.allItems.map(\.id) ?? [])
        let reporter = ScanProgressReporter()
        let engine = makeEngine()
        phase = .scanning
        scanProgress = ScanProgress()
        cleanupReport = nil
        UpkeepLog.app.info("Scan requested (\(trigger == .manual ? "manual" : "scheduled"))")

        let worker = Task.detached(priority: trigger == .manual ? .userInitiated : .utility) {
            await engine.scan(progress: reporter)
        }
        scanWorker = worker

        Task { [weak self] in
            // Sample progress ten times a second instead of pushing every update.
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.scanProgress = reporter.snapshot()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            let result = await worker.value
            poller.cancel()
            guard let self else { return }
            self.scanProgress = reporter.snapshot()
            self.finishScan(result, previousSelection: previousSelection, previousItemIDs: previousItemIDs, trigger: trigger)
        }
    }

    func cancelScan() {
        scanWorker?.cancel()
    }

    private func finishScan(_ result: ScanResult, previousSelection: Set<String>, previousItemIDs: Set<String>, trigger: ScanTrigger) {
        scanWorker = nil
        scanResult = result
        // Keep the user's choices for items that still exist; new items get their default.
        var selection = Set<String>()
        for item in result.allItems where item.isCleanable {
            if previousItemIDs.contains(item.id) {
                if previousSelection.contains(item.id) { selection.insert(item.id) }
            } else if item.risk.isSelectedByDefault {
                selection.insert(item.id)
            }
        }
        selectedItemIDs = selection
        phase = .results
        refreshStorage()

        if !result.wasCancelled {
            lastScanDate = result.finishedAt
            lastReclaimableBytes = result.reclaimableBytes
            UserDefaults.standard.set(result.finishedAt, forKey: Self.lastScanKey)
            UserDefaults.standard.set(Int(result.reclaimableBytes), forKey: Self.lastReclaimableKey)
            if trigger == .scheduled {
                let settings = self.settings
                Task { await NotificationService.notifyIfUseful(reclaimableBytes: result.reclaimableBytes, settings: settings) }
            }
        }
    }

    // MARK: Selection

    func items(in category: CleanupCategory) -> [CleanupItem] {
        scanResult?.result(for: category)?.items ?? []
    }

    func isSelected(_ item: CleanupItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func setSelected(_ item: CleanupItem, _ selected: Bool) {
        guard item.isCleanable else { return }
        if selected { selectedItemIDs.insert(item.id) } else { selectedItemIDs.remove(item.id) }
    }

    func selectionState(for category: CleanupCategory) -> CategorySelectionState {
        let cleanable = items(in: category).filter(\.isCleanable)
        let selected = cleanable.filter { selectedItemIDs.contains($0.id) }.count
        if selected == 0 { return .none }
        return selected == cleanable.count ? .all : .some
    }

    /// Checking a category selects its Safe items. Review items must be picked
    /// individually, unless the category contains nothing else (e.g. Trash).
    func toggleCategory(_ category: CleanupCategory) {
        let cleanable = items(in: category).filter(\.isCleanable)
        if selectionState(for: category) != .none {
            for item in cleanable { selectedItemIDs.remove(item.id) }
        } else {
            let safe = cleanable.filter { $0.risk == .safe }
            for item in (safe.isEmpty ? cleanable : safe) { selectedItemIDs.insert(item.id) }
        }
    }

    func selectAll(in category: CleanupCategory, includeReview: Bool) {
        for item in items(in: category) where item.isCleanable && (includeReview || item.risk == .safe) {
            selectedItemIDs.insert(item.id)
        }
    }

    func deselectAll(in category: CleanupCategory) {
        for item in items(in: category) { selectedItemIDs.remove(item.id) }
    }

    var selectedItems: [CleanupItem] {
        scanResult?.allItems.filter { selectedItemIDs.contains($0.id) && $0.isCleanable } ?? []
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func selectedBytes(in category: CleanupCategory) -> Int64 {
        items(in: category).filter { selectedItemIDs.contains($0.id) && $0.isCleanable }.reduce(0) { $0 + $1.size }
    }

    /// Space that cleaning the selection would actually free now. Items moved to the
    /// Trash don't free space until the Trash is emptied.
    var projectedFreedBytes: Int64 {
        selectedItems.reduce(0) { total, item in
            if settings.moveToTrashWhenPossible, item.method == .delete { return total }
            return total + item.size
        }
    }

    // MARK: Cleanup

    func requestCleanup() {
        let plan = CleanupPlan(selection: selectedItems)
        guard !plan.isEmpty, !isBusy else { return }
        // Review items and permanent deletions always need explicit confirmation.
        if settings.confirmBeforeCleanup || plan.reviewItemCount > 0 || plan.permanentBytes > 0 || !plan.toolCommands.isEmpty {
            pendingPlan = plan
        } else {
            performCleanup(plan)
        }
    }

    func performCleanup(_ plan: CleanupPlan) {
        pendingPlan = nil
        guard !plan.isEmpty, !isBusy else { return }
        refreshStorage()
        storageBeforeCleanup = storage
        phase = .cleaning
        cleanupProgress = CleanupProgress(completed: 0, total: plan.items.count, currentItemName: nil, currentOperation: "Preparing…", bytesReclaimed: 0)
        let engine = makeEngine()
        let options = CleanupOptions(dryRun: false, moveToTrash: settings.moveToTrashWhenPossible)

        let worker = Task.detached(priority: .userInitiated) {
            await engine.cleanup(plan, options: options) { progress in
                Task { @MainActor [weak self] in
                    if self?.phase == .cleaning { self?.cleanupProgress = progress }
                }
            }
        }
        cleanupWorker = worker
        Task { [weak self] in
            let report = await worker.value
            self?.finishCleanup(report)
        }
    }

    func cancelCleanup() {
        cleanupWorker?.cancel()
    }

    private func finishCleanup(_ report: CleanupReport) {
        cleanupWorker = nil
        cleanupReport = report
        // Drop items that are gone from the results; keep failed or skipped ones visible.
        let removedIDs = Set(report.results.filter {
            switch $0.outcome {
            case .removed, .movedToTrash: return true
            default: return false
            }
        }.map(\.id))
        if var result = scanResult {
            for index in result.categories.indices {
                result.categories[index].items.removeAll { removedIDs.contains($0.id) }
            }
            scanResult = result
            lastReclaimableBytes = result.reclaimableBytes
            UserDefaults.standard.set(Int(result.reclaimableBytes), forKey: Self.lastReclaimableKey)
        }
        selectedItemIDs.subtract(removedIDs)
        refreshStorage()
        phase = .finished
    }

    func dismissCleanupSummary() {
        phase = scanResult == nil ? .idle : .results
    }

    // MARK: Large files

    func startLargeFileScan() {
        guard !isScanningLargeFiles else { return }
        let reporter = ScanProgressReporter()
        let engine = makeEngine()
        isScanningLargeFiles = true
        largeFilesProgress = ScanProgress()
        let worker = Task.detached(priority: .userInitiated) {
            await engine.scanLargeFiles(progress: reporter)
        }
        largeFilesWorker = worker
        Task { [weak self] in
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.largeFilesProgress = reporter.snapshot()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            let result = await worker.value
            poller.cancel()
            guard let self else { return }
            self.largeFiles = result
            self.largeFilesProgress = reporter.snapshot()
            self.isScanningLargeFiles = false
            self.largeFilesWorker = nil
        }
    }

    func cancelLargeFileScan() {
        largeFilesWorker?.cancel()
    }

    // MARK: Scheduling

    /// Checks every 15 minutes whether a scheduled scan is due. Scans never run
    /// while the user is busy with results or a cleanup, and never clean anything.
    private func startScheduler() {
        scheduleTimer?.invalidate()
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runScheduledScanIfDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    func runScheduledScanIfDue() {
        guard let interval = settings.scanFrequency.interval else { return }
        guard phase == .idle || phase == .results, pendingPlan == nil else { return }
        if let last = lastScanDate, Date().timeIntervalSince(last) < interval { return }
        startScan(trigger: .scheduled)
    }
}

extension CleanupItem {
    /// Non-optional date for table sorting.
    var modifiedSortDate: Date { modifiedDate ?? .distantPast }
}
