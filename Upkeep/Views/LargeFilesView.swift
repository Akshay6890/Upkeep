import SwiftUI
import UpkeepCore

/// Informational list of large files. There is deliberately no delete action.
struct LargeFilesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sortOrder = [KeyPathComparator(\CleanupItem.size, order: .reverse)]
    @State private var highlighted: Set<CleanupItem.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Large Files")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: CleanupCategory.largeFiles.symbolName)
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Files in your home folder of \(Formatting.bytes(appState.settings.largeFileThresholdBytes)) or more. Upkeep only shows them. Decide yourself what to keep, and use Finder to remove anything you don't need.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS may ask for permission to look in Desktop, Documents and Downloads. Your Library folder and Trash are not included.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if appState.isScanningLargeFiles {
                Button("Stop") { appState.cancelLargeFileScan() }
            } else {
                let title: String = appState.largeFiles == nil ? "Find Large Files" : "Scan Again"
                Button(title) {
                    appState.startLargeFileScan()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if appState.isScanningLargeFiles {
            VStack(spacing: 12) {
                ProgressView()
                Text("\(Formatting.count(appState.largeFilesProgress.itemsAnalyzed)) files checked")
                    .monospacedDigit()
                if let path = appState.largeFilesProgress.currentPath {
                    Text(DisplayPath.string(for: URL(fileURLWithPath: path)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 520)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = appState.largeFiles {
            if result.items.isEmpty {
                ContentUnavailableView(
                    "No large files found",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing in your home folder is \(Formatting.bytes(appState.settings.largeFileThresholdBytes)) or larger.")
                )
            } else {
                table(result.items.sorted(using: sortOrder))
                if !result.issues.isEmpty {
                    Divider()
                    Text(result.issues.map(\.message).joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView(
                "Find large files",
                systemImage: CleanupCategory.largeFiles.symbolName,
                description: Text("This scan is separate from the main scan because it looks through your whole home folder.")
            )
        }
    }

    private func table(_ items: [CleanupItem]) -> some View {
        Table(items, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    PathLabel(url: item.url)
                }
            }
            .width(min: 240, ideal: 420)
            TableColumn("Size", value: \.size) { item in
                Text(Formatting.bytes(item.size)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modifiedSortDate) { item in
                Text(DateText.modified(item.modifiedDate))
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: CleanupItem.ID.self) { ids in
            let selected = items.filter { ids.contains($0.id) }
            Button("Reveal in Finder") {
                for item in selected { FinderService.reveal(item.url) }
            }
            Button("Copy Path") {
                if let first = selected.first { FinderService.copyPath(first.url) }
            }
            .disabled(selected.count != 1)
        } primaryAction: { ids in
            for item in items where ids.contains(item.id) { FinderService.reveal(item.url) }
        }
    }
}

struct IssuesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let issues = appState.scanResult?.issues, !issues.isEmpty {
                List {
                    if issues.contains(where: { $0.kind == .permissionDenied }) {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("macOS denied access to some locations, so Upkeep skipped them. The rest of the scan is unaffected.")
                                Text("To include them, open System Settings › Privacy & Security › Full Disk Access, turn on Upkeep, then scan again.")
                                    .foregroundStyle(.secondary)
                                Button("Open Privacy Settings…") { PermissionService.openFullDiskAccessSettings() }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    ForEach(CleanupCategory.allCases) { category in
                        let categoryIssues = issues.filter { $0.category == category }
                        if !categoryIssues.isEmpty {
                            Section(category.title) {
                                ForEach(categoryIssues) { issue in
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(issue.message)
                                            if let path = issue.path {
                                                Text(path)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: symbol(for: issue.kind))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No scan issues",
                    systemImage: "checkmark.circle",
                    description: Text(appState.scanResult == nil ? "Run a scan to see any locations Upkeep couldn't read." : "Upkeep could read every location it scanned.")
                )
            }
        }
        .navigationTitle("Scan Issues")
    }

    private func symbol(for kind: ScanIssue.Kind) -> String {
        switch kind {
        case .permissionDenied: return "lock"
        case .notFound: return "questionmark.folder"
        case .toolFailed: return "wrench.and.screwdriver"
        case .skipped: return "forward"
        case .other: return "exclamationmark.circle"
        }
    }
}
