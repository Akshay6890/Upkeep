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
            detail
        }
        .onChange(of: sidebarSelection) { _, _ in
            appState.openCategory = nil
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
            if let category = appState.openCategory {
                CategoryView(category: category)
                    .id(category)
            } else {
                DashboardView(showIssues: { sidebarSelection = .issues })
            }
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
