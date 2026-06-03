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

    // Native toolbar (matches Compose/Archive) — replaces the old in-content WorkBar,
    // which doubled up with the system titlebar into a second strip.
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
                    .help("自动裁判打分")
            }
            if app.livePhase == .done {
                Button { Exporter.exportWithPanel(app.live) } label: { Image(systemName: "square.and.arrow.up") }
                    .help("导出 trace / 日志 / 指标 / 裁判到文件夹")
            }
            if running {
                Button { app.cancelRun() } label: { Image(systemName: "stop.fill") }.help("停止运行")
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
            VStack(spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    Text("你").font(Theme.ui(12, .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Theme.ink)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(app.live.task).font(Theme.ui(14.5)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .background(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
                        .cardShadow()
                }
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(app.live.laneIndices, id: \.self) { i in
                            ConvoLaneHeader(run: app.live.runs[i], cfg: app.live.configs[i], lane: i)
                                .frame(maxWidth: .infinity)
                            if i < app.live.laneIndices.upperBound - 1 {
                                Rectangle().frame(width: 1).foregroundStyle(Theme.line2)
                            }
                        }
                    }
                    .background(Theme.panel2)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

                    VStack(spacing: density.turnGap) {
                        ForEach(rounds) { round in
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(app.live.laneIndices, id: \.self) { lane in
                                    ConvoRoundCell(
                                        turns: round.turns[lane] ?? [],
                                        run: app.live.runs[lane],
                                        lane: lane,
                                        isFirstRound: round.index == 0,
                                        isLastRound: round.index == rounds.last?.index
                                    )
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    if lane < app.live.laneIndices.upperBound - 1 {
                                        Rectangle().frame(width: 1).foregroundStyle(Theme.line2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(density.cardPad)
                }
                .panel()
            }
            .frame(maxWidth: maxW).frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.vertical, 24)
        }
        .background(Theme.bg)
    }

    private var rounds: [ConvoRound] {
        let perLane = Dictionary(uniqueKeysWithValues: app.live.laneIndices.map { lane in
            (lane, splitRounds(app.live.runs[lane].turns))
        })
        let maxCount = max(1, perLane.values.map(\.count).max() ?? 0)
        return (0..<maxCount).map { idx in
            var turns: [Int: [Turn]] = [:]
            for lane in app.live.laneIndices {
                turns[lane] = perLane[lane]?.indices.contains(idx) == true ? perLane[lane]![idx] : []
            }
            return ConvoRound(index: idx, turns: turns)
        }
    }

    private func splitRounds(_ turns: [Turn]) -> [[Turn]] {
        var groups: [[Turn]] = [[]]
        for turn in turns {
            if turn.kind == .user {
                groups.append([turn])
            } else {
                groups[groups.count - 1].append(turn)
            }
        }
        return groups
    }
}

private struct ConvoRound: Identifiable {
    let index: Int
    let turns: [Int: [Turn]]
    var id: Int { index }
}

private struct ConvoLaneHeader: View {
    let run: RunResult
    let cfg: AgentConfig
    let lane: Int

    var body: some View {
        HStack {
            AgentTag(agentId: cfg.agentId, model: cfg.model, lane: lane)
            Spacer(minLength: 8)
            statusView
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    @ViewBuilder private var statusView: some View {
        switch run.status {
        case .running: StatusPill(kind: .running, text: "运行中", spinning: true)
        case .done:    StatusPill(kind: .done, text: "完成 · \(Fmt.sec(run.metrics.latencyMs))")
        case .failed:  StatusPill(kind: .failed, text: "失败")
        case .pending: StatusPill(kind: .idle, text: "待运行")
        }
    }
}

private struct ConvoRoundCell: View {
    @EnvironmentObject var app: AppState
    @Environment(\.density) private var density
    let turns: [Turn]
    let run: RunResult
    let lane: Int
    let isFirstRound: Bool
    let isLastRound: Bool

    private var visibleTurns: [Turn] {
        app.prefs.showThinking ? turns : turns.filter { $0.kind != .think }
    }
    private var working: Bool { run.status == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: density.turnGap) {
            if isFirstRound, let err = run.error, run.status == .failed {
                errorBox(err)
            }
            if isFirstRound, run.turns.isEmpty, !working, run.error == nil {
                EmptyState(icon: "read", title: "无转录记录",
                           message: "这次运行没有产生可显示的对话步骤")
            }
            ForEach(visibleTurns) { turn in
                TurnView(turn: turn, lane: lane)
            }
            if isLastRound, working {
                HStack(spacing: 8) {
                    Spinner(size: 14)
                    TypingDots()
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, density.colGap / 2)
    }

    private func errorBox(_ err: String) -> some View {
        Text(err)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.bad)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(Theme.delBG)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
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
                    ForEach(app.live.configs.indices, id: \.self) { i in
                        if i > 0 { Rectangle().frame(width: 1, height: 24).foregroundStyle(Theme.line) }
                        laneMetrics(i)
                    }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Segmented(view: $app.artifactView)
                DiffToggle()
                Button { app.compareOpen = true } label: {
                    HStack(spacing: 7) { SFIcon(name: "expand", size: 14); Text("放大对比").font(Theme.ui(12.5, .semibold)) }
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(app.accentColor).clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                }.buttonStyle(.plain)
                Rectangle().frame(width: 1, height: 24).foregroundStyle(Theme.line)
                Text("你的判断").font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.ink3)
                HStack(spacing: 6) {
                    ForEach(app.live.configs.indices, id: \.self) { i in voteBtn(Lane.label(i), "\(Lane.label(i)) 更好") }
                    voteBtn("tie", "平局")
                }
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

    private func voteBtn(_ key: String, _ label: String) -> some View {
        let on = app.live.vote == key
        return Button { app.vote(key) } label: {
            Text(label).font(Theme.ui(12.5, .semibold))
                .foregroundStyle(on ? .white : Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? app.accentColor : Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(on ? app.accentColor : Theme.line3, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }.buttonStyle(.plain)
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
