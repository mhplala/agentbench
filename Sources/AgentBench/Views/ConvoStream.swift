import SwiftUI

// One agent's conversation column (header + streaming turns).
struct ConvoColumn: View {
    @EnvironmentObject var app: AppState
    @Environment(\.density) private var density
    let run: RunResult
    let cfg: AgentConfig
    let lane: Int

    private var working: Bool { run.status == .running }

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                AgentTag(agentId: cfg.agentId, model: cfg.model, lane: lane)
                Spacer(minLength: 8)
                statusView
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(Theme.panel2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            // body
            VStack(alignment: .leading, spacing: density.turnGap) {
                if let err = run.error, run.status == .failed {
                    errorBox(err)
                }
                if visibleTurns.isEmpty && !working && run.error == nil {
                    EmptyState(icon: "read", title: "无转录记录",
                               message: "这次运行没有产生可显示的对话步骤")
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
            .padding(density.cardPad)
        }
        // Flat panel — the column organizes by hairline + background level, not a
        // shadowed card. Cards are reserved for the artifact inside.
        .panel()
    }

    private var visibleTurns: [Turn] {
        app.prefs.showThinking ? run.turns : run.turns.filter { $0.kind != .think }
    }

    @ViewBuilder private var statusView: some View {
        switch run.status {
        case .running: StatusPill(kind: .running, text: "运行中", spinning: true)
        case .done:    StatusPill(kind: .done, text: "完成 · \(Fmt.sec(run.metrics.latencyMs))")
        case .failed:  StatusPill(kind: .failed, text: "失败")
        case .pending: StatusPill(kind: .idle, text: "待运行")
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

    private var canUndoAuto: Bool {
        turn.kind == .user && turn.summary.contains("自动应答")
            && app.live.runs.indices.contains(lane) && app.live.runs[lane].status != .running
    }

    private var userView: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("你").font(Theme.ui(11, .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(turn.summary).font(Theme.ui(13.5)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color(hex: 0x14141A, alpha: 0.05))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                if canUndoAuto {
                    Button { app.undoAutoAnswer(lane) } label: {
                        HStack(spacing: 5) {
                            SFIcon(name: "arrow.uturn.backward", size: 11)
                            Text("撤销自动应答 · 改我来回复").font(Theme.ui(11.5, .semibold))
                        }
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .overlay(Capsule().stroke(Theme.line3, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("退回到该 agent 提问的状态，再用底部输入栏（目标选「仅 \(Lane.label(lane))」）手动回复")
                }
            }
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
            VStack(alignment: .leading, spacing: 10) {
                // summary renders Markdown (headings/lists/bold/code), as plain prose
                MarkdownText(text: turn.summary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !turn.files.isEmpty {
                    let wd = app.live.runs.indices.contains(lane) ? app.live.runs[lane].workdir : nil
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(turn.files) { f in FileRow(f: f, baseDir: wd) }
                    }
                    .padding(11)
                    .panel(Theme.rSm, fill: Theme.panel2, stroke: Theme.line2)
                }

                // the artifact is the one genuine product → the one real card
                ArtifactViewer(turn: turn, lane: lane)
                    .panel(Theme.rSm, stroke: Theme.line2)
                    .cardShadow()
            }
        }
    }
}

struct FileRow: View {
    let f: FileChange
    var baseDir: String? = nil       // the lane's workspace; nil/purged → not clickable
    @State private var hover = false

    private var isDeleted: Bool { f.deleted == true }
    private var fileURL: URL? { isDeleted ? nil : FinderOpen.fileURL(base: baseDir, rel: f.path) }
    private var openable: Bool { FinderOpen.exists(fileURL) }

    var body: some View {
        if openable, let url = fileURL {
            Button { FinderOpen.open(url) } label: { content }
                .buttonStyle(.plain)
                .background((hover ? Theme.line2.opacity(0.5) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rXs)))
                .onHover { hover = $0 }
                .pointingHand()
                .help("点击用默认 App 打开 · 右键在 Finder 中显示")
                .contextMenu {
                    Button { FinderOpen.open(url) } label: { Label("打开", systemImage: "arrow.up.forward.app") }
                    Button { FinderOpen.reveal(url) } label: { Label("在 Finder 中显示", systemImage: "folder") }
                }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            SFIcon(name: isDeleted ? "x" : "edit", size: 12)
                .foregroundStyle(isDeleted ? Theme.delFG : Theme.ink3)
            Text(f.path).font(Theme.mono(12))
                .foregroundStyle(isDeleted ? Theme.ink3 : Theme.ink)
                .strikethrough(isDeleted)
                .lineLimit(1).truncationMode(.middle)
            if openable {
                SFIcon(name: "arrow.up.forward", size: 9).foregroundStyle(Theme.ink3)
                    .opacity(hover ? 1 : 0.45)
            }
            Spacer(minLength: 6)
            if isDeleted {
                Text("已删除").font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.delFG)
            } else {
                if f.add > 0 { Text("+\(f.add)").font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.addFG) }
                if f.del > 0 { Text("−\(f.del)").font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.delFG) }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// Safety banner over an untrusted preview; lets the user opt into JS/assets/network.
// Built on the shared WarningBanner vocabulary, over a material so it stays legible
// against arbitrary preview content.
struct TrustBanner: View {
    @EnvironmentObject var app: AppState
    let lane: Int
    var body: some View {
        WarningBanner(text: "未信任 · 脚本/资源/网络已禁用",
                      actionLabel: "信任并运行",
                      action: { app.trust(lane) },
                      accent: app.accentColor)
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

    private var canOpenInBrowser: Bool {
        guard turn.previewHTML != nil,
              app.live.runs.indices.contains(lane),
              let f = app.live.runs[lane].previewFileURL else { return false }
        return FileManager.default.fileExists(atPath: f.path)
    }

    // The lane's isolated workspace, if it still exists on disk (purged for old runs).
    private var workdirURL: URL? {
        guard app.live.runs.indices.contains(lane) else { return nil }
        let wd = app.live.runs[lane].workdir
        guard !wd.isEmpty, FileManager.default.fileExists(atPath: wd) else { return nil }
        return URL(fileURLWithPath: wd)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Segmented(view: $app.artifactView)
                Spacer()
                Text(app.artifactView == "code" ? "\(turn.codeLineCount) 行"
                                                 : (turn.previewHTML == nil ? "无可渲染预览" : "渲染产物"))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                // only offer "open in browser" when there's an actual file on disk to
                // open — openInBrowser needs previewFileURL, so an inline-only preview
                // would make the button a no-op.
                if let wd = workdirURL {
                    IconButton(icon: "folder", help: "在 Finder 中打开产物文件夹", size: 13) { FinderOpen.reveal(wd) }
                }
                if canOpenInBrowser {
                    IconButton(icon: "browser", help: "在浏览器打开", size: 13) { app.openInBrowser(lane) }
                }
                IconButton(icon: "expand", help: "放大对比", size: 13) { app.compareOpen = true }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
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
        EmptyState(icon: "info", title: "此任务无可视化预览", message: "切到「代码」查看 diff")
            .frame(maxWidth: .infinity).frame(height: 300)
            .background(Theme.panel2)
    }
}
