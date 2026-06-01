import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var app: AppState
    private var running: Bool { app.livePhase == .running }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Convo()
                if !running {
                    FollowupComposer()
                    ActionBar()
                }
            }
            JudgeDrawer()
            if app.compareOpen { CompareOverlay().transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.2), value: app.compareOpen)
        .navigationTitle(app.live.task.isEmpty ? "对比" : app.live.task)
        .toolbar { workspaceToolbar }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 9) {
                ForEach(app.live.configs.indices, id: \.self) { i in
                    if i > 0 { Text("vs").font(Theme.mono(10)).foregroundStyle(Theme.ink3) }
                    AgentTag(agentId: app.live.configs[i].agentId, model: app.live.configs[i].model, lane: i)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .frame(maxWidth: app.live.laneCount > 2 ? 680 : 460)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !running && app.live.judgeOn {
                Button { app.judgeOpen.toggle() } label: { Image(systemName: "hammer.fill") }
                    .help("自动裁判")
            }
            if app.livePhase == .done {
                Button { Exporter.exportWithPanel(app.live) } label: { Image(systemName: "square.and.arrow.up") }
                    .help("导出 trace / 日志 / 指标 / 裁判到文件夹")
            }
            if running {
                Button { app.cancelRun() } label: { Image(systemName: "stop.fill") }
                    .help("停止运行")
            } else {
                Button { app.runComparison() } label: { Image(systemName: "arrow.clockwise") }
                    .help("重跑").disabled(!app.canRun())
            }
        }
    }
}

struct Convo: View {
    @EnvironmentObject var app: AppState
    @Environment(\.density) private var density
    private var maxW: CGFloat { app.live.laneCount > 2 ? 1640 : 1100 }
    var body: some View {
        ScrollView {
            VStack(spacing: density.convoGap) {
                HStack(alignment: .top, spacing: 12) {
                    Text("你").font(Theme.ui(12, .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Theme.identity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(app.live.task).font(Theme.ui(14.5)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .panel(fill: Theme.panel2)   // flat prompt panel, no shadow
                }
                HStack(alignment: .top, spacing: density.colGap) {
                    ForEach(app.live.laneIndices, id: \.self) { i in
                        ConvoColumn(run: app.live.runs[i], cfg: app.live.configs[i], lane: i)
                    }
                }
            }
            .frame(maxWidth: maxW).frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.vertical, 24)
        }
        .background(Theme.bg)
    }
}

// Follow-up composer: continue the same session(s) with a next instruction.
struct FollowupComposer: View {
    @EnvironmentObject var app: AppState
    @State private var target: Set<Int> = []   // empty = all lanes

    private var targetLabel: String {
        target.isEmpty ? "全部" : target.sorted().map { Lane.label($0) }.joined(separator: "+")
    }
    private func resolved() -> Set<Int> { target.isEmpty ? Set(app.live.configs.indices) : target }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("发给全部") { target = [] }
                ForEach(app.live.configs.indices, id: \.self) { i in
                    Button("仅 \(Lane.label(i)) · \(AgentCatalog.spec(app.live.configs[i].agentId).name)") { target = [i] }
                }
            } label: {
                HStack(spacing: 5) {
                    SFIcon(name: "send", size: 12); Text(targetLabel).font(Theme.ui(12.5, .semibold)); SFIcon(name: "chevronD", size: 10)
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.panel2)
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            TextField("继续给 agent 下一步指令，测试持续任务推进…（⌘↵ 发送）", text: $app.followupText)
                .textFieldStyle(.plain).font(Theme.ui(13.5))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                .onSubmit { app.sendFollowup(resolved()) }

            Button { app.sendFollowup(resolved()) } label: {
                HStack(spacing: 6) { SFIcon(name: "send", size: 13); Text("发送").font(Theme.ui(13, .semibold)) }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(app.followupText.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.ink3 : app.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            }
            .buttonStyle(.plain)
            .disabled(app.followupText.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(Theme.panel.opacity(0.97))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .top)
    }
}

struct ActionBar: View {
    @EnvironmentObject var app: AppState
    private var allMetrics: [Metrics] { app.live.runs.map { $0.metrics } }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(app.live.laneIndices, id: \.self) { i in
                        if i > 0 { Rectangle().frame(width: 1, height: 24).foregroundStyle(Theme.line) }
                        laneMetrics(i)
                    }
                }
            }
            Spacer(minLength: 12)
            // distinct groups: [view mode] · [commands] · [your vote]
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Segmented(view: $app.artifactView)
                    DiffToggle()
                }
                IconButton(icon: "expand", help: "放大对比", prominent: true, tint: app.accentColor) {
                    app.compareOpen = true
                }
                Rectangle().frame(width: 1, height: 22).foregroundStyle(Theme.line)
                VoteGroup()
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.panel.opacity(0.97))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
    }

    private func laneMetrics(_ i: Int) -> some View {
        HStack(spacing: 8) {
            LaneBadge(lane: i)
            MetricChips(m: app.live.runs[i].metrics, peers: allMetrics)
        }
    }
}

// Compact segmented vote control: one A/B/C/D pill per lane + 平局, with a small
// leading label so it reads as a dedicated "your verdict" group.
struct VoteGroup: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 8) {
            SFIcon(name: "trophy", size: 12).foregroundStyle(Theme.ink3)
                .help("你的判断")
            HStack(spacing: 2) {
                ForEach(app.live.configs.indices, id: \.self) { i in
                    seg(Lane.label(i), Lane.label(i), help: "\(Lane.label(i)) 更好")
                }
                seg("tie", "=", help: "平局")
            }
            .padding(3).background(Theme.panel2)
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
    }

    private func seg(_ key: String, _ label: String, help: String) -> some View {
        let on = app.live.vote == key
        return Button { app.vote(key) } label: {
            Text(label).font(Theme.ui(12.5, .bold))
                .foregroundStyle(on ? .white : Theme.ink2)
                .frame(minWidth: 24).padding(.horizontal, 6).padding(.vertical, 4)
                .background(on ? app.accentColor : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
        }
        .buttonStyle(.plain).help(help)
    }
}

// Small A/B/C/D lane badge (lane 0 filled).
struct LaneBadge: View {
    let lane: Int
    var box: CGFloat = 20
    var body: some View {
        let primary = lane == 0
        Text(Lane.label(lane)).font(Theme.ui(box * 0.55, .bold))
            .foregroundStyle(primary ? .white : Theme.ink)
            .frame(width: box, height: box)
            .background(primary ? Theme.ink : .clear)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(primary ? .clear : Theme.ink, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
