import SwiftUI
import UpkeepCore

/// Columns an item list can be sorted by.
enum ItemSortKey: String, CaseIterable {
    case name
    case size
    case modified
    case risk
}

struct ItemSort: Equatable {
    var key: ItemSortKey = .size
    var ascending = false

    func sorted(_ items: [CleanupItem]) -> [CleanupItem] {
        items.sorted { a, b in
            let ordered: Bool
            switch key {
            case .name: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: ordered = a.size < b.size
            case .modified: ordered = a.modifiedSortDate < b.modifiedSortDate
            case .risk: ordered = a.risk < b.risk
            }
            return ascending ? ordered : !ordered
        }
    }

    mutating func toggle(_ newKey: ItemSortKey) {
        if key == newKey {
            ascending.toggle()
        } else {
            key = newKey
            // Names read naturally A→Z; sizes and dates are most useful largest/newest first.
            ascending = newKey == .name || newKey == .risk
        }
    }
}

/// A plain, lazily rendered list of cleanup items with a sortable header.
///
/// Built from ordinary SwiftUI views instead of `Table`, which rendered empty
/// rows inside the split view's detail column.
struct ItemList: View {
    let items: [CleanupItem]
    @Binding var sort: ItemSort
    @Binding var highlighted: CleanupItem.ID?
    /// When non-nil, rows show a checkbox bound through these closures.
    var isSelected: ((CleanupItem) -> Bool)?
    var setSelected: ((CleanupItem, Bool) -> Void)?
    var selectionDisabled = false
    var showsSafety = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            // Keep rows inside the list; never draw them over the header or title bar.
            .clipped()
        }
        .clipped()
    }

    private var showsCheckbox: Bool { isSelected != nil && setSelected != nil }

    private var header: some View {
        HStack(spacing: 12) {
            if showsCheckbox {
                Color.clear.frame(width: 18, height: 1)
            }
            sortButton("Name", .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton("Size", .size)
                .frame(width: 90, alignment: .trailing)
            sortButton("Modified", .modified)
                .frame(width: 110, alignment: .trailing)
            if showsSafety {
                sortButton("Safety", .risk)
                    .frame(width: 100, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sortButton(_ title: String, _ key: ItemSortKey) -> some View {
        Button {
            sort.toggle(key)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort.key == key {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.caption.weight(sort.key == key ? .semibold : .regular))
            .foregroundStyle(sort.key == key ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
        .accessibilityLabel("Sort by \(title)")
    }

    private func row(_ item: CleanupItem) -> some View {
        let isHighlighted = highlighted == item.id
        return HStack(spacing: 12) {
            if let isSelected, let setSelected {
                Toggle(isOn: Binding(get: { isSelected(item) }, set: { setSelected(item, $0) })) {
                    Text("Select \(item.name)")
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isCleanable || selectionDisabled)
                .help(item.isCleanable ? "Include in cleanup" : "Upkeep won't remove this item")
                .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DisplayPath.string(for: item.url))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Formatting.bytes(item.size))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Text(DateText.modified(item.modifiedDate))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            if showsSafety {
                RiskBadge(risk: item.risk, compact: true)
                    .frame(width: 100, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { FinderService.reveal(item.url) }
        .onTapGesture { highlighted = isHighlighted ? nil : item.id }
        .help(item.reason)
        .contextMenu {
            Button("Reveal in Finder") { FinderService.reveal(item.url) }
            Button("Copy Path") { FinderService.copyPath(item.url) }
            if let setSelected, item.isCleanable, !selectionDisabled {
                Divider()
                Button("Include in Cleanup") { setSelected(item, true) }
                Button("Exclude from Cleanup") { setSelected(item, false) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }
}

/// A compact filter field used in page headers (instead of `.searchable`, which
/// disturbed the sidebar layout in the split view).
struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter items", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .frame(maxWidth: 260)
    }
}
