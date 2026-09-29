import SwiftUI
import UpkeepCore

enum SidebarItem: Hashable {
    case overview
    case largeFiles
    case issues
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sidebarSelection: SidebarItem? = .overview
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section {
                    Label("Overview", systemImage: "leaf")
                        .tag(SidebarItem.overview)
                    Label("Large Files", systemImage: CleanupCategory.largeFiles.symbolName)
                        .tag(SidebarItem.largeFiles)
                    Label {
                        Text("Scan Issues")
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .badge(issueCount)
                    .tag(SidebarItem.issues)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: CleanupCategory.self) { category in
                        CategoryView(category: category)
                    }
            }
        }
        .onChange(of: sidebarSelection) { _, _ in
            path = NavigationPath()
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
        switch sidebarSelection ?? .overview {
        case .overview:
            DashboardView(showIssues: { sidebarSelection = .issues })
        case .largeFiles:
            LargeFilesView()
        case .issues:
            IssuesView()
        }
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
