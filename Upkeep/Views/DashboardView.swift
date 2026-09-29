import SwiftUI
import UpkeepCore

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    var showIssues: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderCard()
                if appState.fullDiskAccess == .denied {
                    PermissionBanner()
                }
                switch appState.phase {
                case .idle, .scanning, .cleaning:
                    ScanView()
                case .results:
                    ResultsView(showIssues: showIssues)
                case .finished:
                    if let report = appState.cleanupReport {
                        CleanupSummaryView(report: report)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Upkeep")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if appState.phase == .scanning {
                    Button {
                        appState.cancelScan()
                    } label: {
                        Label("Stop Scan", systemImage: "stop.circle")
                    }
                    .help("Stop scanning")
                } else {
                    Button {
                        appState.startScan()
                    } label: {
                        Label("Scan Mac", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isBusy)
                    .help("Scan your Mac for reclaimable storage (⌘R)")
                }
            }
        }
        .onAppear {
            appState.refreshStorage()
            appState.refreshPermissions()
        }
    }
}

/// App identity plus real volume capacity, modeled on the Upkeep card design.
struct HeaderCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    AppIconTile(size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upkeep")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("Keep your Mac clean, without the guesswork.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Pill(text: SystemInfo.chipDescription)
                }

                if let storage = appState.storage {
                    VStack(alignment: .leading, spacing: 10) {
                        StorageBar(
                            usedFraction: storage.usedFraction,
                            reclaimableFraction: reclaimableFraction(storage)
                        )
                        HStack(spacing: 28) {
                            StatView(title: "Available", value: Formatting.bytes(storage.availableCapacity))
                            StatView(title: "Used", value: Formatting.bytes(storage.usedCapacity))
                            StatView(title: "Total", value: Formatting.bytes(storage.totalCapacity))
                            Spacer()
                            StatView(title: "Last scan", value: DateText.scanTime(appState.lastScanDate))
                        }
                    }
                } else {
                    Text("Storage information is unavailable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reclaimableFraction(_ storage: StorageSummary) -> Double {
        guard appState.phase == .results, storage.totalCapacity > 0 else { return 0 }
        return Double(appState.projectedFreedBytes) / Double(storage.totalCapacity)
    }
}

struct PermissionBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Some locations need Full Disk Access")
                        .font(.headline)
                    Text("Upkeep scans most locations without extra permissions. macOS protects your Trash and some app caches, so they are skipped unless you grant Upkeep Full Disk Access in System Settings. Upkeep never tries to bypass these protections.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Privacy Settings…") { PermissionService.openFullDiskAccessSettings() }
                        Button("Check Again") { appState.refreshPermissions() }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}
