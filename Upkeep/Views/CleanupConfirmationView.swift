import SwiftUI
import UpkeepCore

/// Shows exactly what will be removed before anything happens.
struct CleanupConfirmationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let plan: CleanupPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIconTile(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're about to remove \(Formatting.bytes(plan.totalBytes)).")
                        .font(.title3.weight(.semibold))
                    Text(Formatting.plural(plan.items.count, "item") + " will be \(appState.settings.moveToTrashWhenPossible ? "moved to the Trash where possible" : "removed").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(plan.groups) { group in
                    HStack {
                        Image(systemName: group.category.symbolName)
                            .frame(width: 22)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(group.category.title)
                        Text("· \(Formatting.plural(group.items.count, "item"))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if group.highestRisk != .safe {
                            RiskBadge(risk: group.highestRisk, compact: true)
                        }
                        Text(Formatting.bytes(group.totalBytes))
                            .monospacedDigit()
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    if group.id != plan.groups.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))

            if !plan.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(warning.contains("permanently") ? Color.red : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("Each item is checked again right before removal. Anything that changed since the scan is skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    appState.pendingPlan = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Clean Selected", role: .destructive) {
                    appState.performCleanup(plan)
                    dismiss()
                }
                .buttonStyle(ProminentButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct CleanupSummaryView: View {
    @EnvironmentObject private var appState: AppState
    let report: CleanupReport
    @State private var showFailures = true

    var body: some View {
        Card(padding: 28) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(report.failed.isEmpty ? Color.accentColor : Color.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cleanup complete")
                            .font(.title2.weight(.semibold))
                        Text(headline)
                            .font(.title3)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("Done") { appState.dismissCleanupSummary() }
                        .buttonStyle(ProminentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }

                HStack(spacing: 28) {
                    StatView(title: "Removed", value: Formatting.count(report.succeeded.count))
                    StatView(title: "Skipped", value: Formatting.count(report.skipped.count))
                    StatView(title: "Failed", value: Formatting.count(report.failed.count))
                    Spacer()
                    if let before = appState.storageBeforeCleanup, let after = appState.storage {
                        StatView(title: "Available before", value: Formatting.bytes(before.availableCapacity))
                        StatView(title: "Available now", value: Formatting.bytes(after.availableCapacity))
                    }
                }

                if report.movedToTrashBytes > 0 {
                    Text("\(Formatting.bytes(report.movedToTrashBytes)) was moved to the Trash. Empty the Trash to free that space.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("macOS may take a moment to update available space, and APFS snapshots can keep some space in use until they expire.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                let problems = report.failed + report.skipped
                if !problems.isEmpty {
                    DisclosureGroup(isExpanded: $showFailures) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(problems) { result in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.item.name)
                                        .font(.callout.weight(.medium))
                                    Text(result.outcome.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    PathLabel(url: result.item.url)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Skipped and failed items (\(problems.count))")
                            .font(.headline)
                    }
                }
            }
        }
    }

    private var headline: String {
        var text = "\(Formatting.bytes(report.reclaimedBytes)) reclaimed"
        if report.movedToTrashBytes > 0 {
            text += " · \(Formatting.bytes(report.movedToTrashBytes)) moved to Trash"
        }
        return text
    }
}
