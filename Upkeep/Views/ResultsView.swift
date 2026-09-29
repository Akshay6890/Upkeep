import SwiftUI
import UpkeepCore

struct ResultsView: View {
    @EnvironmentObject private var appState: AppState
    var showIssues: () -> Void

    var body: some View {
        if let result = appState.scanResult {
            VStack(alignment: .leading, spacing: 16) {
                SummaryCard(result: result)
                if !result.issues.isEmpty {
                    IssuesBanner(issues: result.issues, showIssues: showIssues)
                }
                let available = result.availableCategories
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16)], spacing: 16) {
                    ForEach(available) { category in
                        CategoryCard(result: category)
                    }
                }
                let unavailable = result.categories.filter { !$0.isAvailable }
                if !unavailable.isEmpty {
                    Text("Not found on this Mac: " + unavailable.map(\.category.title).joined(separator: ", ") + ".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Upkeep can't guarantee that every item is safe for every setup. Review what's selected. You stay in control of what gets removed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct SummaryCard: View {
    @EnvironmentObject private var appState: AppState
    let result: ScanResult

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reclaimable Storage")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(Formatting.bytes(result.reclaimableBytes))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accentGradient)
                            .monospacedDigit()
                        Text(breakdown)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            appState.requestCleanup()
                        } label: {
                            Text(appState.selectedItems.isEmpty ? "Clean Selected" : "Clean Selected (\(Formatting.bytes(appState.selectedBytes)))")
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(ProminentButtonStyle(large: true))
                        .disabled(appState.selectedItems.isEmpty || appState.isBusy)
                        Button("Scan Again") { appState.startScan() }
                            .disabled(appState.isBusy)
                    }
                }

                if let storage = appState.storage {
                    Divider()
                    HStack(spacing: 28) {
                        StatView(title: "Available now", value: Formatting.bytes(storage.availableCapacity))
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        StatView(
                            title: "After cleaning selection",
                            value: Formatting.bytes(storage.projectedAvailable(afterFreeing: appState.projectedFreedBytes))
                        )
                        Spacer()
                        StatView(title: "Selected", value: Formatting.plural(appState.selectedItems.count, "item"))
                    }
                    if appState.settings.moveToTrashWhenPossible && appState.selectedItems.contains(where: { $0.method == .delete }) {
                        Text("“Move to Trash” is on: space from moved items is freed when you empty the Trash.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if result.wasCancelled {
                    Label("The scan was stopped early, so these results are incomplete.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var breakdown: String {
        let safe = result.reclaimableBytes(risk: .safe)
        let review = result.reclaimableBytes(risk: .review)
        var parts = ["\(Formatting.bytes(safe)) safe to remove"]
        if review > 0 { parts.append("\(Formatting.bytes(review)) to review") }
        parts.append("scanned \(DateText.scanTime(result.finishedAt))")
        return parts.joined(separator: " · ")
    }
}

struct IssuesBanner: View {
    let issues: [ScanIssue]
    var showIssues: () -> Void

    var body: some View {
        let denied = issues.filter { $0.kind == .permissionDenied }.reduce(0) { $0 + $1.count }
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message(denied: denied))
                .font(.callout)
            Spacer()
            Button("Show Details", action: showIssues)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    private func message(denied: Int) -> String {
        if denied > 0 {
            return "Skipped \(Formatting.plural(denied, "location")) because macOS denied access."
        }
        return "\(Formatting.plural(issues.count, "issue")) came up during the scan."
    }
}

struct CategoryCard: View {
    @EnvironmentObject private var appState: AppState
    let result: CategoryResult

    var body: some View {
        let category = result.category
        let cleanable = result.cleanableItems
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    if cleanable.isEmpty {
                        Image(systemName: "square")
                            .font(.title3)
                            .foregroundStyle(.quaternary)
                            .accessibilityHidden(true)
                    } else {
                        TriStateCheckbox(
                            state: appState.selectionState(for: category),
                            label: "Select \(category.title)"
                        ) {
                            appState.toggleCategory(category)
                        }
                    }
                    Image(systemName: category.symbolName)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(.system(.headline, design: .rounded).weight(.bold))
                        Text(subtitle(cleanable))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Formatting.bytes(result.cleanableSize))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    if let risk = result.highestCleanableRisk {
                        RiskBadge(risk: cleanable.allSatisfy({ $0.risk == .safe }) ? .safe : risk)
                    }
                    if category == .trash && !cleanable.isEmpty {
                        Label("Permanent", systemImage: "exclamationmark.octagon")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                    if !result.issues.isEmpty {
                        Label(Formatting.plural(result.issues.count, "issue"), systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text(category.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if mixesRisks(cleanable) {
                        Text("Review items are selected individually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !result.items.isEmpty {
                        Button("Show \(Formatting.plural(result.items.count, "item"))") {
                            appState.navigate(to: .category(category))
                        }
                    }
                }
            }
        }
        .opacity(cleanable.isEmpty ? 0.75 : 1)
    }

    private func subtitle(_ cleanable: [CleanupItem]) -> String {
        if cleanable.isEmpty { return "Nothing to clean" }
        let files = cleanable.reduce(0) { $0 + $1.fileCount }
        var text = Formatting.plural(files, "file")
        let selected = appState.selectedBytes(in: result.category)
        if selected > 0 && selected != result.cleanableSize {
            text += " · \(Formatting.bytes(selected)) selected"
        }
        return text
    }

    private func mixesRisks(_ items: [CleanupItem]) -> Bool {
        items.contains { $0.risk == .safe } && items.contains { $0.risk == .review }
    }
}
