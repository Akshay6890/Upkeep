import SwiftUI
import UpkeepCore

/// App shell: a sidebar that is always visible and always reflects the current
/// page, and a detail area with a Back button on every page except Overview.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
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

    private var sidebar: some View {
        List(selection: selectionBinding) {
            Section {
                Label("Overview", systemImage: "leaf")
                    .tag(SidebarItem.overview)
            }

            if let result = appState.scanResult, !result.availableCategories.isEmpty {
                Section("Cleanup") {
                    ForEach(result.availableCategories) { category in
                        Label(category.category.title, systemImage: category.category.symbolName)
                            .badge(Text(Formatting.bytes(category.cleanableSize)).monospacedDigit())
                            .tag(SidebarItem.category(category.category))
                    }
                }
            }

            Section("Tools") {
                Label("Large Files", systemImage: CleanupCategory.largeFiles.symbolName)
                    .tag(SidebarItem.largeFiles)
                Label("Scan Issues", systemImage: "exclamationmark.circle")
                    .badge(issueCount)
                    .tag(SidebarItem.issues)
            }
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

    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { appState.destination },
            set: { item in
                if let item { appState.navigate(to: item) }
            }
        )
    }

    private var issueCount: Int {
        appState.scanResult?.issues.count ?? 0
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )
    }
}
