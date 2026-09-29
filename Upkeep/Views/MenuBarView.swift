import SwiftUI
import UpkeepCore

/// Contents of the menu bar item. Everything shown comes from the last real scan;
/// nothing runs in the background from here unless the user chooses Scan Now.
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Upkeep")
        Text("Last scan: \(DateText.scanTime(appState.lastScanDate))")
        Text(reclaimableText)

        Divider()

        Button(scanTitle) {
            appState.startScan()
            showMainWindow()
        }
        .disabled(appState.isBusy)

        Button("Open Upkeep") {
            showMainWindow()
        }

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Upkeep") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var scanTitle: String {
        appState.phase == .scanning ? "Scanning…" : "Scan Now"
    }

    private var reclaimableText: String {
        switch appState.phase {
        case .scanning:
            return "Scanning… \(Formatting.bytes(appState.scanProgress.bytesDiscovered)) found"
        case .cleaning:
            return "Cleaning…"
        default:
            guard let bytes = appState.lastReclaimableBytes else { return "No scan yet" }
            return "\(Formatting.bytes(bytes)) reclaimable"
        }
    }

    private func showMainWindow() {
        openWindow(id: WindowID.main)
        NSApplication.shared.activate()
    }
}
