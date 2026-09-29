import SwiftUI
import UpkeepCore

/// Individual items of one category, with selection, sorting, filtering and details.
struct CategoryView: View {
    @EnvironmentObject private var appState: AppState
    let category: CleanupCategory

    @State private var sort = ItemSort()
    @State private var highlighted: CleanupItem.ID?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if allItems.isEmpty {
                emptyState
            } else if visibleItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ItemList(
                    items: visibleItems,
                    sort: $sort,
                    highlighted: $highlighted,
                    isSelected: { appState.isSelected($0) },
                    setSelected: { appState.setSelected($0, $1) },
                    selectionDisabled: appState.isBusy
                )
                if let item = detailItem {
                    Divider()
                    ItemDetailView(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(category.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Select Safe Items") { appState.selectAll(in: category, includeReview: false) }
                    Button("Select All Items") { appState.selectAll(in: category, includeReview: true) }
                    Divider()
                    Button("Deselect All") { appState.deselectAll(in: category) }
                } label: {
                    Label("Selection", systemImage: "checklist")
                }
                .disabled(appState.isBusy || allItems.isEmpty)
                .help("Select or deselect items in this category")
                .pointingHandCursor(!appState.isBusy && !allItems.isEmpty)

                Button {
                    appState.requestCleanup()
                } label: {
                    Label("Clean Selected", systemImage: "trash")
                }
                .help("Review and clean everything you've selected, in all categories")
                .disabled(appState.isBusy || appState.selectedItemIDs.isEmpty)
            }
        }
    }

    private var allItems: [CleanupItem] { appState.items(in: category) }

    private var issues: [ScanIssue] {
        appState.scanResult?.result(for: category)?.issues ?? []
    }

    private var visibleItems: [CleanupItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? allItems : allItems.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.url.path.localizedCaseInsensitiveContains(query)
        }
        return sort.sorted(filtered)
    }

    private var detailItem: CleanupItem? {
        guard let highlighted else { return nil }
        return allItems.first { $0.id == highlighted }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: category.symbolName)
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Formatting.bytes(appState.selectedBytes(in: category))) of \(Formatting.bytes(cleanableSize)) selected")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            if !allItems.isEmpty {
                FilterField(text: $searchText)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var emptyState: some View {
        let denied = issues.contains { $0.kind == .permissionDenied }
        if denied {
            ContentUnavailableView {
                Label("macOS blocked access", systemImage: "lock.shield")
            } description: {
                Text(issues.map(\.message).joined(separator: "\n"))
            } actions: {
                Button("Open Privacy Settings…") { PermissionService.openFullDiskAccessSettings() }
                Button("Scan Again") { appState.startScan() }
            }
        } else {
            ContentUnavailableView(
                "Nothing to clean",
                systemImage: category.symbolName,
                description: Text(issues.isEmpty ? "No items in this category." : issues.map(\.message).joined(separator: "\n"))
            )
        }
    }

    private var cleanableSize: Int64 {
        allItems.filter(\.isCleanable).reduce(0) { $0 + $1.size }
    }
}

struct ItemDetailView: View {
    let item: CleanupItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    RiskBadge(risk: item.risk)
                    if item.isPermanent {
                        Label("Permanent", systemImage: "exclamationmark.octagon")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Reveal in Finder") { FinderService.reveal(item.url) }
                    Button("Copy Path") { FinderService.copyPath(item.url) }
                }
                Text(item.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(item.reason)
                    .font(.callout)
                ForEach(item.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    StatView(title: "Size", value: Formatting.bytes(item.size))
                    StatView(title: "Files", value: Formatting.count(item.fileCount))
                    StatView(title: "Modified", value: DateText.modified(item.modifiedDate))
                    StatView(title: "Cleanup", value: item.method.description)
                    StatView(title: "Found in", value: item.source)
                }
                if !item.detailPaths.isEmpty {
                    DisclosureGroup("Paths reported by the tool (\(item.detailPaths.count))") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(item.detailPaths, id: \.self) { path in
                                Text(path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 150, idealHeight: 190, maxHeight: 260)
    }
}
