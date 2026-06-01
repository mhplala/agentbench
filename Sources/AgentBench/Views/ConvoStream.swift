import SwiftUI

// One agent's conversation column (header + streaming turns).
struct ConvoColumn: View {
    @EnvironmentObject var app: AppState
    let run: RunResult
    let cfg: AgentConfig
    let lane: Int

    private var working: Bool { run.status == .running }

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                AgentTag(agentId: cfg.agentId, model: cfg.model, lane: lane)
                if let pn = app.providerName(cfg), cfg.providerId != nil {
                    HStack(spacing: 4) {
                        SFIcon(name: "globe", size: 9)
                        Text(pn).font(Theme.mono(10))
                    }
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.panel2)
                    .overlay(Capsule().stroke(Theme.line2, lineWidth: 1)).clipShape(Capsule())
                }
                Spacer(minLength: 8)
                statusView
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(Theme.panel2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            // body
            VStack(alignment: .leading, spacing: 12) {
                if let err = run.error, run.status == .failed {
                    errorBox(err)
                }
                ForEach(visibleTurns) { turn in
                    TurnView(turn: turn, lane: lane)
                }
                if working {
                    HStack(spacing: 8) {
                        Spinner(size: 14)
                        TypingDots()
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
        .cardShadow()
    }

    private var visibleTurns: [Turn] {
        app.prefs.showThinking ? run.turns : run.turns.filter { $0.kind != .think }
    }

    @ViewBuilder private var statusView: some View {
        switch run.status {
        case .running:
            HStack(spacing: 6) { Spinner(); Text("运行中").font(Theme.mono(11.5, .semibold)) }
                .foregroundStyle(Theme.ink2)
        case .done:
            HStack(spacing: 6) {
                SFIcon(name: "check", size: 12)
                Text("完成 · \(Fmt.sec(run.metrics.latencyMs))").font(Theme.mono(11.5, .semibold))
            }.foregroundStyle(Theme.good)
        case .failed:
            HStack(spacing: 6) {
                SFIcon(name: "warn", size: 12)
                Text("失败").font(Theme.mono(11.5, .semibold))
            }.foregroundStyle(Theme.bad)
        case .pending:
            Text("待运行").font(Theme.mono(11.5)).foregroundStyle(Theme.ink3)
        }
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

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle().fill(Theme.ink3).frame(width: 4, height: 4)
                    .opacity(0.25 + 0.75 * max(0, sin(phase - Double(i) * 0.6)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
    }
}

// A single turn: think / tool chip / answer card.
struct TurnView: View {
    @EnvironmentObject var app: AppState
    let turn: Turn
    let lane: Int

    var body: some View {
        switch turn.kind {
        case .think:   thinkView
        case .tool:    if let t = turn.tool { ToolChip(step: t) }
        case .answer:  AnswerCard(turn: turn, lane: lane)
        case .user:    userView
        }
    }

    private var userView: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("你").font(Theme.ui(11, .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(turn.summary).font(Theme.ui(13.5)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(hex: 0x14141A, alpha: 0.05))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .padding(.top, 4)
    }

    private var thinkView: some View {
        HStack(alignment: .top, spacing: 10) {
            iconBubble("brain")
            VStack(alignment: .leading, spacing: 7) {
                Text("推理").font(Theme.ui(10.5, .bold)).tracking(1.2).foregroundStyle(Theme.ink3)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(turn.plan.indices, id: \.self) { i in
                        HStack(alignment: .top, spacing: 7) {
                            Text("•").foregroundStyle(Theme.ink3)
                            Text(turn.plan[i]).font(Theme.ui(13)).foregroundStyle(Theme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func iconBubble(_ name: String) -> some View {
        SFIcon(name: name, size: 13).foregroundStyle(Theme.ink3)
            .frame(width: 26, height: 26)
            .background(Theme.panel2)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct ToolChip: View {
    let step: ToolStep
    var body: some View {
        HStack(spacing: 9) {
            SFIcon(name: icon, size: 13)
                .foregroundStyle(step.kind == .shell ? .white : Theme.ink2)
                .frame(width: 20, height: 20)
                .background(step.kind == .shell ? Theme.ink : Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(step.label).font(Theme.ui(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            if !step.detail.isEmpty {
                Text(step.detail).font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        .padding(.leading, 36)
    }
    private var icon: String {
        switch step.kind { case .edit: return "edit"; case .shell: return "terminal"
        case .read: return "read"; default: return "info" }
    }
}

// The agent's answer: summary + changed files + artifact viewer (preview/code).
struct AnswerCard: View {
    @EnvironmentObject var app: AppState
    let turn: Turn
    let lane: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentGlyph(agentId: app.live.configs.indices.contains(lane) ? app.live.configs[lane].agentId : "claude-code",
                       lane: lane, box: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(turn.summary)
                    .font(Theme.ui(13.5)).foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15).padding(.vertical, 13)

                if !turn.files.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(turn.files) { f in FileRow(f: f) }
                    }
                    .padding(.horizontal, 15).padding(.bottom, 13)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)
                }
                ArtifactViewer(turn: turn, lane: lane)
            }
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.r))
        }
    }
}

struct FileRow: View {
    let f: FileChange
    private var isDeleted: Bool { f.deleted == true }
    var body: some View {
        HStack(spacing: 8) {
            SFIcon(name: isDeleted ? "x" : "edit", size: 12)
                .foregroundStyle(isDeleted ? Theme.delFG : Theme.ink3)
            Text(f.path).font(Theme.mono(12))
                .foregroundStyle(isDeleted ? Theme.ink3 : Theme.ink)
                .strikethrough(isDeleted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if isDeleted {
                Text("已删除").font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.delFG)
            } else {
                if f.add > 0 { Text("+\(f.add)").font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.addFG) }
                if f.del > 0 { Text("−\(f.del)").font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.delFG) }
            }
        }
    }
}

// Safety banner over an untrusted preview; lets the user opt into JS/assets/network.
struct TrustBanner: View {
    @EnvironmentObject var app: AppState
    let lane: Int
    var body: some View {
        HStack(spacing: 8) {
            SFIcon(name: "warn", size: 12).foregroundStyle(Theme.ink2)
            Text("未信任 · 脚本/资源/网络已禁用")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.ink2)
            Spacer(minLength: 8)
            Button { app.trust(lane) } label: {
                Text("信任并运行").font(Theme.ui(11.5, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.ink).clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .top)
    }
}

// 预览 / 代码 tabs inside an answer card.
struct ArtifactViewer: View {
    @EnvironmentObject var app: AppState
    let turn: Turn
    let lane: Int

    private var diffMap: [DiffMark]? { app.diffMap(lane) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab("preview", "play", "预览")
                tab("code", "terminal", "代码")
                Spacer()
                Text(app.artifactView == "code" ? "\(turn.code.components(separatedBy: "\n").count) 行"
                                                 : (turn.previewHTML == nil ? "无可渲染预览" : "渲染产物"))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
                if turn.previewHTML != nil {
                    Button { app.openInBrowser(lane) } label: {
                        SFIcon(name: "browser", size: 13).foregroundStyle(Theme.ink3)
                    }
                    .buttonStyle(.plain).help("在浏览器打开")
                    .padding(.leading, 8)
                }
                Button { app.compareOpen = true } label: {
                    SFIcon(name: "expand", size: 13).foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain).help("放大对比")
                .padding(.leading, 8)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.panel2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            Group {
                if app.artifactView == "preview" {
                    if let html = turn.previewHTML {
                        let run = app.live.runs.indices.contains(lane) ? app.live.runs[lane] : RunResult()
                        ZStack(alignment: .bottom) {
                            HTMLPreview(html: html, baseDir: run.previewBaseDir,
                                        fileURL: run.previewFileURL, readAccessDir: run.workdir,
                                        trusted: app.isTrusted(lane))
                            if !app.isTrusted(lane) { TrustBanner(lane: lane) }
                        }
                        .frame(height: 300)
                    } else {
                        noPreview
                    }
                } else {
                    CodeView(text: turn.code, diffMap: diffMap)
                        .frame(height: 300)
                }
            }
        }
        .background(Theme.panel)
    }

    private var noPreview: some View {
        VStack(spacing: 6) {
            SFIcon(name: "info", size: 18).foregroundStyle(Theme.ink3)
            Text("此任务无可视化预览").font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
            Text("切到「代码」查看 diff").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity).frame(height: 300)
        .background(Theme.panel2)
    }

    private func tab(_ key: String, _ icon: String, _ label: String) -> some View {
        let on = app.artifactView == key
        return Button {
            app.artifactView = key
        } label: {
            HStack(spacing: 6) { SFIcon(name: icon, size: 12); Text(label).font(Theme.ui(12, .semibold)) }
                .foregroundStyle(on ? Theme.ink : Theme.ink3)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(on ? Theme.panel : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
                .overlay(RoundedRectangle(cornerRadius: Theme.rXs)
                    .stroke(on ? Theme.line2 : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
