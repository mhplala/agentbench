import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @State private var collapsed = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(collapsed: $collapsed)
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 680)
        .background(Theme.bg)
        .background(WindowConfigurator())   // Tahoe chrome: lights over sidebar
        .environment(\.colorScheme, .light)
        .ignoresSafeArea(.container, edges: .top)   // content under the titlebar
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
