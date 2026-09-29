import SwiftUI
import UpkeepCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ScanSettingsView()
                .tabItem { Label("Scan", systemImage: "magnifyingglass") }
            CleanupSettingsView()
                .tabItem { Label("Cleanup", systemImage: "trash") }
            LocationsSettingsView()
                .tabItem { Label("Locations", systemImage: "folder") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ScanSettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    private let largeFileThresholds: [Int64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000]

    var body: some View {
        Form {
            Section {
                Picker("Scan automatically", selection: $store.settings.scanFrequency) {
                    ForEach(ScanFrequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
            } footer: {
                Text("Automatic scans only run while Upkeep is open (for example, in the menu bar). They never clean anything.")
            }

            Section("Include") {
                Toggle("Logs and crash reports", isOn: $store.settings.includeLogs)
                Toggle("Developer caches (Xcode, Python)", isOn: $store.settings.includeDeveloperCaches)
                Toggle("Package-manager caches (Homebrew, SwiftPM, npm, Yarn, pnpm)", isOn: $store.settings.includePackageManagerCaches)
            }

            Section {
                Stepper(value: $store.settings.logMinimumAgeDays, in: UpkeepSettings.ageRange) {
                    LabeledContent("Minimum age for logs", value: days(store.settings.logMinimumAgeDays))
                }
                Stepper(value: $store.settings.crashReportMinimumAgeDays, in: UpkeepSettings.ageRange) {
                    LabeledContent("Minimum age for crash reports", value: days(store.settings.crashReportMinimumAgeDays))
                }
                Stepper(value: $store.settings.temporaryFileMinimumAgeDays, in: UpkeepSettings.ageRange) {
                    LabeledContent("Minimum age for temporary files", value: days(store.settings.temporaryFileMinimumAgeDays))
                }
                Picker("Large file threshold", selection: $store.settings.largeFileThresholdBytes) {
                    ForEach(largeFileThresholds, id: \.self) { value in
                        Text(Formatting.bytes(value)).tag(value)
                    }
                }
            } header: {
                Text("Age and size")
            } footer: {
                Text("Changes apply to the next scan.")
            }
        }
        .formStyle(.grouped)
    }

    private func days(_ value: Int) -> String {
        value == 1 ? "1 day" : "\(value) days"
    }
}

private struct CleanupSettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Confirm before cleanup", isOn: $store.settings.confirmBeforeCleanup)
            } footer: {
                Text("Upkeep always asks first when the selection includes Review items, permanent Trash deletion or developer-tool commands.")
            }
            Section {
                Toggle("Move removable files to Trash when possible", isOn: $store.settings.moveToTrashWhenPossible)
            } footer: {
                Text("Moved items can be recovered from the Trash, but their space isn't freed until you empty it. Items already in the Trash and tool-managed caches are always removed directly.")
            }
            Section {
                Toggle("Show protected items", isOn: $store.settings.showProtectedItems)
            } footer: {
                Text("Lists items Upkeep found but will never clean (for example, caches used by iCloud or folders it can't identify), so you can see why they were left alone.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct LocationsSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var appState: AppState
    @State private var folderError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Full Disk Access") {
                    switch appState.fullDiskAccess {
                    case .granted:
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Label("Not granted", systemImage: "xmark.circle").foregroundStyle(.orange)
                    case .unknown:
                        Label("Unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Open Privacy Settings…") { PermissionService.openFullDiskAccessSettings() }
                    Button("Check Again") { appState.refreshPermissions() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Without Full Disk Access, Upkeep skips your Trash and some app caches that macOS protects. Everything else still works.")
            }

            Section {
                if store.developerFolders.isEmpty {
                    Text("No developer folders")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.developerFolders) { folder in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)
                        Text(DisplayPath.string(for: folder.url))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            store.removeDeveloperFolder(folder)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(folder.url.lastPathComponent)")
                    }
                }
                Button("Add Folder…") { addFolder() }
                if let folderError {
                    Text(folderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Developer folders")
            } footer: {
                Text("Upkeep looks for __pycache__ folders only inside the folders you add here, and only removes them if they contain nothing but compiled bytecode. Hidden folders and node_modules are skipped.")
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.refreshPermissions() }
    }

    private func addFolder() {
        folderError = nil
        guard let url = PermissionService.chooseFolder(message: "Choose a folder that contains your Python projects.") else { return }
        do {
            try store.addDeveloperFolder(url)
        } catch {
            folderError = error.localizedDescription
        }
    }
}

private struct NotificationSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var permissionDenied = false

    private let thresholds: [Int64] = [500_000_000, 1_000_000_000, 5_000_000_000, 10_000_000_000]

    var body: some View {
        Form {
            Section {
                Toggle("Notify after automatic scans", isOn: notifyBinding)
                Picker("Only when at least", selection: $store.settings.notificationThresholdBytes) {
                    ForEach(thresholds, id: \.self) { value in
                        Text(Formatting.bytes(value)).tag(value)
                    }
                }
                .disabled(!store.settings.notifyAfterScheduledScan)
                if permissionDenied {
                    Text("Notifications are turned off for Upkeep in System Settings › Notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("For example: “Upkeep found 8.2 GB of reclaimable storage.” At most one notification per day.")
            }
            Section {
                Toggle("Show Upkeep in the menu bar", isOn: $store.settings.showMenuBarItem)
            } footer: {
                Text("The menu bar item shows your last scan and lets you scan or open Upkeep. With it on, Upkeep keeps running after you close its window.")
            }
        }
        .formStyle(.grouped)
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { store.settings.notifyAfterScheduledScan },
            set: { enabled in
                store.settings.notifyAfterScheduledScan = enabled
                guard enabled else { return }
                Task {
                    let granted = await NotificationService.requestAuthorization()
                    permissionDenied = !granted
                    if !granted { store.settings.notifyAfterScheduledScan = false }
                }
            }
        )
    }
}
