import SwiftUI
import UpkeepCore

/// The main scan card: the "Scan Mac" call to action, live scan progress, or
/// cleanup progress, depending on the phase.
struct ScanView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Card(padding: 28) {
            switch appState.phase {
            case .scanning:
                ScanningProgressView(progress: appState.scanProgress, onCancel: { appState.cancelScan() })
            case .cleaning:
                CleaningProgressView(progress: appState.cleanupProgress, onCancel: { appState.cancelCleanup() })
            default:
                idle
            }
        }
    }

    private var idle: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Find reclaimable storage")
                    .font(.title3.weight(.semibold))
                Text("Upkeep looks for caches, old logs, temporary files, Trash and developer data that can safely be regenerated. Nothing is removed until you review it and confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                appState.startScan()
            } label: {
                Text("Scan Mac")
                    .font(.headline)
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

struct ScanningProgressView: View {
    let progress: ScanProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text("Step \(min(progress.completedCategories + 1, max(progress.totalCategories, 1))) of \(max(progress.totalCategories, 1))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            ProgressView(value: progress.fractionComplete)
                .progressViewStyle(.linear)
                .accessibilityLabel("Scan progress")

            HStack(spacing: 28) {
                StatView(title: "Items analyzed", value: Formatting.count(progress.itemsAnalyzed))
                StatView(title: "Reclaimable so far", value: Formatting.bytes(progress.bytesDiscovered))
            }

            if let path = progress.currentPath {
                Text(DisplayPath.string(for: URL(fileURLWithPath: path)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Analyzing \(path)")
            }
        }
    }

    private var title: String {
        guard let category = progress.currentCategory else { return "Preparing scan…" }
        return "Scanning \(category.title.lowercased())…"
    }
}

struct CleaningProgressView: View {
    let progress: CleanupProgress?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleaning…")
                        .font(.title3.weight(.semibold))
                    if let progress {
                        Text("\(progress.completed) of \(progress.total) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Stop", action: onCancel)
                    .help("Stops after the current item. Items already removed stay removed.")
            }
            ProgressView(value: progress?.fractionComplete ?? 0)
                .accessibilityLabel("Cleanup progress")
            HStack(spacing: 28) {
                StatView(title: "Reclaimed so far", value: Formatting.bytes(progress?.bytesReclaimed ?? 0))
            }
            if let operation = progress?.currentOperation {
                Text(operation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
