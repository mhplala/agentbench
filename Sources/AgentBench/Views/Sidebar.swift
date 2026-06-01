import SwiftUI

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @Binding var collapsed: Bool

    private var groups: [(String, [Session])] {
        let order = ["今天", "昨天", "本周", "更早"]
        let grouped = Dictionary(grouping: app.historySessions, by: { $0.groupLabel })
        return order.compactMap { key in grouped[key].map { (key, $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            // clear the traffic-light strip (lights float here over the sidebar)
            Color.clear.frame(height: 28)
            // brand
            HStack(spacing: 8) {
                if !collapsed {
                    HStack(spacing: 9) {
                        Text("▚").font(.system(size: 17))
                        Text("AgentBench").font(Theme.ui(15.5, .bold)).tracking(-0.3)
                    }.foregroundStyle(Theme.ink)
                    Spacer()
                }
                Button { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } } label: {
                    SFIcon(name: "sidebar", size: 16).foregroundStyle(Theme.ink3)
                }.buttonStyle(.plain).help("折叠侧栏")
            }
            .padding(.horizontal, collapsed ? 0 : 16).padding(.top, 6).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)

            // new comparison
            Button { app.newComparison() } label: {
                HStack(spacing: 8) {
                    SFIcon(name: "plus", size: 15)
                    if !collapsed { Text("新建对比").font(Theme.ui(13.5, .semibold)) }
                }
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9).padding(.horizontal, collapsed ? 9 : 12)
                .background(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                .cardShadow()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.bottom, 8)

            // sessions
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // current
                    group(label: "当前") {
                        currentRow
                    }
                    ForEach(groups, id: \.0) { (label, items) in
                        group(label: label) {
                            ForEach(items) { s in
                                archivedRow(s)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            // footer
            Divider().foregroundStyle(Theme.line2)
            Button { app.activeId = "settings" } label: {
                HStack(spacing: 9) {
                    SFIcon(name: "gear", size: 15)
                    if !collapsed { Text("设置").font(Theme.ui(13, .medium)) }
                    if !collapsed { Spacer() }
                }
                .foregroundStyle(Theme.ink2)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: collapsed ? Theme.sideCollapsed : Theme.sideW)
        .background(VisualEffectView(material: .sidebar))   // native Tahoe vibrancy
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Theme.line), alignment: .trailing)
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder private func group<C: View>(label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !collapsed {
                Text(label).font(Theme.ui(10.5, .bold)).tracking(1.0).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
            }
            content()
        }
    }

    private var currentRow: some View {
        let on = app.activeId == "live"
        return Button { app.selectLive() } label: {
            HStack(alignment: .top, spacing: collapsed ? 0 : 10) {
                Circle().fill(Theme.good).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Theme.good.opacity(0.25), lineWidth: 3))
                    .padding(.top, 5).padding(.horizontal, collapsed ? 0 : 6)
                if !collapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.live.task.isEmpty ? "新建对比" : app.live.task)
                            .font(Theme.ui(13, .medium)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Text(app.live.configs.map { AgentCatalog.spec($0.agentId).name }.joined(separator: " · "))
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
            }
            .padding(collapsed ? 8 : 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color(hex: 0x14141A, alpha: 0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .buttonStyle(.plain)
    }

    private func archivedRow(_ s: Session) -> some View {
        let on = app.activeId == s.id
        let winner = s.verdict?.winner ?? (s.vote ?? "tie")
        return Button { app.activeId = s.id } label: {
            HStack(alignment: .top, spacing: collapsed ? 0 : 10) {
                winBadge(winner)
                if !collapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.task).font(Theme.ui(13, .medium)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Text(s.configs.map { AgentCatalog.spec($0.agentId).name }.joined(separator: " · ") + " · \(s.dateLabel)")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
            }
            .padding(collapsed ? 8 : 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color(hex: 0x14141A, alpha: 0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("以此重跑") { app.rerun(from: s) }
            Button("删除", role: .destructive) { app.deleteSession(s.id) }
        }
    }

    private func winBadge(_ w: String) -> some View {
        let tie = w == "tie"
        return Text(tie ? "=" : w)
            .font(Theme.ui(11, .bold))
            .foregroundStyle(tie ? Theme.ink3 : .white)
            .frame(width: 20, height: 20)
            .background(tie ? Color.clear : Theme.ink)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tie ? Theme.line3 : .clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.top, 1)
    }
}
