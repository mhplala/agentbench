import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var prefs = Prefs.shared
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 288, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // light theme is scoped to the content so the system sidebar/toolbar
                // keep their native (glass) materials on Tahoe.
                .environment(\.colorScheme, .light)
        }
        .navigationSplitViewStyle(.automatic)
        .frame(minWidth: 1040, minHeight: 700)
        .environment(\.density, DensityMetrics.from(prefs.density))
    }

    @ViewBuilder private var mainArea: some View {
        if app.activeId == "settings" {
            SettingsView()
        } else if app.activeId == "live" {
            switch app.livePhase {
            case .compose: ComposeView()
            default:       WorkspaceView()
            }
        } else if let s = app.archived(app.activeId) {
            ArchiveView(session: s)
        } else {
            ComposeView()
        }
    }
}
