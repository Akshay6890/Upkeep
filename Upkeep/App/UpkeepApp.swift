import SwiftUI
import UpkeepCore

@main
struct UpkeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var appState: AppState

    init() {
        let store = SettingsStore()
        _settingsStore = StateObject(wrappedValue: store)
        _appState = StateObject(wrappedValue: AppState(settingsStore: store))
    }

    var body: some Scene {
        Window("Upkeep", id: WindowID.main) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(settingsStore)
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 1000, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Mac") { appState.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(appState.isBusy)
                Button("Stop Scan") { appState.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(appState.phase != .scanning)
                Divider()
                Button("Clean Selected…") { appState.requestCleanup() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(appState.isBusy || appState.selectedItems.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(settingsStore)
        }

        MenuBarExtra(isInserted: menuBarBinding) {
            MenuBarContent()
                .environmentObject(appState)
        } label: {
            Image(systemName: "leaf")
                .accessibilityLabel("Upkeep")
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.showMenuBarItem },
            set: { settingsStore.settings.showMenuBarItem = $0 }
        )
    }
}

enum WindowID {
    static let main = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpkeepLog.app.info("Upkeep launched")
    }

    /// With the menu bar item enabled, Upkeep keeps running after its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !SettingsStore.loadSettings().showMenuBarItem
    }
}
