import AppKit
import SwiftUI
import UpkeepCore

/// App shell: a fixed sidebar and a detail area laid out side by side, both below
/// the title bar.
///
/// This deliberately doesn't use `NavigationSplitView`: on macOS 14 its columns
/// extend under the toolbar, which let page content and sidebar rows slide up
/// behind the title bar and get stuck there.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 230)
                .frame(maxHeight: .infinity)
                .background(SidebarBackground())
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipped()
        }
        .toolbar {
            if appState.destination != .overview {
                ToolbarItem(placement: .navigation) {
                    Button {
                        appState.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back (⌘[)")
                }
            }
        }
        .sheet(item: $appState.pendingPlan) { plan in
            CleanupConfirmationView(plan: plan)
        }
        .alert("Upkeep", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.destination {
        case .overview:
            DashboardView(showIssues: { appState.navigate(to: .issues) })
        case .category(let category):
            CategoryView(category: category)
                .id(category)
        case .largeFiles:
            LargeFilesView()
        case .issues:
            IssuesView()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )
    }
}

/// The sidebar: plain buttons in a scroll view. The highlighted row always
/// matches `AppState.destination`.
struct SidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(title: "Overview", symbol: "leaf", item: .overview)

                if let result = appState.scanResult, !result.availableCategories.isEmpty {
                    SidebarSectionHeader(title: "Cleanup")
                    ForEach(result.availableCategories) { category in
                        SidebarRow(
                            title: category.category.title,
                            symbol: category.category.symbolName,
                            item: .category(category.category),
                            badge: Formatting.bytes(category.cleanableSize)
                        )
                    }
                }

                SidebarSectionHeader(title: "Tools")
                SidebarRow(title: "Large Files", symbol: CleanupCategory.largeFiles.symbolName, item: .largeFiles)
                SidebarRow(
                    title: "Scan Issues",
                    symbol: "exclamationmark.circle",
                    item: .issues,
                    badge: issueCount > 0 ? Formatting.count(issueCount) : nil
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private var issueCount: Int {
        appState.scanResult?.issues.count ?? 0
    }
}

private struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let symbol: String
    let item: SidebarItem
    var badge: String?

    var body: some View {
        let isSelected = appState.destination == item
        Button {
            appState.navigate(to: item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let badge {
                    Text(badge)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The standard translucent macOS sidebar material.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
