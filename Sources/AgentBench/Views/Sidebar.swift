import SwiftUI

// Native sidebar: a `List` with `.listStyle(.sidebar)` so macOS Tahoe renders the
// floating rounded inset chrome (and pulls the traffic lights inside it) for free.
// Selection is drawn ourselves via a custom row background — the native sidebar pill
// forces the saturated system-accent blue regardless of `.tint`, which clashes with
// the monochrome design, so we opt out of it and paint a calm neutral pill instead.
struct Sidebar: View {
    @EnvironmentObject var app: AppState

    private var groups: [(String, [Session])] {
        let order = ["今天", "昨天", "本周", "更早"]
        let grouped = Dictionary(grouping: app.historySessions, by: { $0.groupLabel })
        return order.compactMap { key in grouped[key].map { (key, $0) } }
    }

    var body: some View {
        List {
            Section {
                currentRow
                    .rowSelect(app.activeId == "live") { app.activeId = "live" }
            } header: { Text("当前") }

            ForEach(groups, id: \.0) { (label, items) in
                Section {
                    ForEach(items) { s in
                        archivedRow(s)
                            .rowSelect(app.activeId == s.id) { app.activeId = s.id }
                    }
                } header: { Text(label) }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 30)
        .safeAreaInset(edge: .top, spacing: 0) { brandHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { settingsFooter }
    }

    // MARK: brand + new comparison (top)
    private var brandHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("▚").font(.system(size: 15))
                Text("AgentBench").font(Theme.ui(14.5, .bold)).tracking(-0.3)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.ink)

            Button { app.newComparison() } label: {
                HStack(spacing: 8) {
                    SFIcon(name: "plus", size: 15)
                    Text("新建对比").font(Theme.ui(13.5, .semibold))
                }
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
    }

    // MARK: settings (bottom)
    private var settingsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button { app.activeId = "settings" } label: {
                HStack(spacing: 9) {
                    SFIcon(name: "gear", size: 15)
                    Text("设置").font(Theme.ui(13, .medium))
                    Spacer()
                }
                .foregroundStyle(app.activeId == "settings" ? Theme.ink : Theme.ink2)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    // MARK: rows
    private var currentRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Theme.good).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Theme.good.opacity(0.25), lineWidth: 3))
                .padding(.top, 5).padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.live.task.isEmpty ? "新建对比" : app.live.task)
                    .font(Theme.ui(13, .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                Text(app.live.configs.map { AgentCatalog.spec($0.agentId).name }.joined(separator: " · "))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func archivedRow(_ s: Session) -> some View {
        let winner = s.verdict?.winner ?? (s.vote ?? "tie")
        return HStack(alignment: .top, spacing: 10) {
            winBadge(winner)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.task).font(Theme.ui(13, .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                Text(s.configs.map { AgentCatalog.spec($0.agentId).name }.joined(separator: " · ") + " · \(s.dateLabel)")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
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

private extension View {
    // Custom sidebar selection: a calm neutral pill + tap-to-select, replacing the
    // native system-blue highlight. Inset slightly to read as a floating pill.
    func rowSelect(_ selected: Bool, _ action: @escaping () -> Void) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.selection : Color.clear)
                .padding(.horizontal, 6).padding(.vertical, 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
