import SwiftUI
import UpkeepCore

/// Individual items of one category, with selection, sorting, search and details.
struct CategoryView: View {
    @EnvironmentObject private var appState: AppState
    let category: CleanupCategory

    @State private var sortOrder = [KeyPathComparator(\CleanupItem.size, order: .reverse)]
    @State private var highlighted: Set<CleanupItem.ID> = []
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if allItems.isEmpty {
                ContentUnavailableView("Nothing to clean", systemImage: category.symbolName, description: Text("No items in this category."))
            } else {
                table
                    .frame(minHeight: 220, maxHeight: .infinity)
                if let item = detailItem {
                    Divider()
                    ItemDetailView(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(category.title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter items")
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
                .disabled(appState.isBusy)
            }
        }
    }

    private var allItems: [CleanupItem] { appState.items(in: category) }

    private var visibleItems: [CleanupItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? allItems : allItems.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.url.path.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted(using: sortOrder)
    }

    private var detailItem: CleanupItem? {
        guard highlighted.count == 1, let id = highlighted.first else { return nil }
        return allItems.first { $0.id == id }
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
            Spacer()
        }
        .padding(16)
    }

    private var cleanableSize: Int64 {
        allItems.filter(\.isCleanable).reduce(0) { $0 + $1.size }
    }

    private var table: some View {
        Table(visibleItems, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle(isOn: selectionBinding(for: item)) {
                    Text("Select \(item.name)")
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isCleanable || appState.isBusy)
                .help(item.isCleanable ? "Include in cleanup" : "Upkeep won't remove this item")
            }
            .width(24)

            TableColumn("Name", value: \.name) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    PathLabel(url: item.url)
                }
                .help(item.reason)
            }
            .width(min: 220, ideal: 360)

            TableColumn("Size", value: \.size) { item in
                Text(Formatting.bytes(item.size))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Modified", value: \.modifiedSortDate) { item in
                Text(DateText.modified(item.modifiedDate))
            }
            .width(min: 90, ideal: 110)

            TableColumn("Safety", value: \.risk) { item in
                RiskBadge(risk: item.risk, compact: true)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: CleanupItem.ID.self) { ids in
            let items = allItems.filter { ids.contains($0.id) }
            Button("Reveal in Finder") {
                for item in items { FinderService.reveal(item.url) }
            }
            Button("Copy Path") {
                FinderService.copyPath(items.first?.url ?? URL(fileURLWithPath: "/"))
            }
            .disabled(items.count != 1)
            Divider()
            Button("Include in Cleanup") {
                for item in items { appState.setSelected(item, true) }
            }
            .disabled(!items.contains(where: \.isCleanable) || appState.isBusy)
            Button("Exclude from Cleanup") {
                for item in items { appState.setSelected(item, false) }
            }
            .disabled(appState.isBusy)
        } primaryAction: { ids in
            for item in allItems where ids.contains(item.id) { FinderService.reveal(item.url) }
        }
    }

    private func selectionBinding(for item: CleanupItem) -> Binding<Bool> {
        Binding(
            get: { appState.isSelected(item) },
            set: { appState.setSelected(item, $0) }
        )
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
