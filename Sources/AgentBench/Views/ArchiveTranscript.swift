import SwiftUI

// Read-only transcript of an archived session. Self-contained: it renders from the
// passed-in `session` only and never reaches into `app.live`, so any archived
// comparison can be re-opened and fully re-viewed (turns, tools, answers, artifacts).
struct ArchiveTranscript: View {
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(session.runs.indices, id: \.self) { i in
                ArchiveLaneColumn(run: session.runs[i],
                                  cfg: session.configs.indices.contains(i) ? session.configs[i] : .empty,
                                  lane: i)
            }
        }
    }
}

// One archived agent's conversation column (header + frozen turns).
struct ArchiveLaneColumn: View {
    @EnvironmentObject var app: AppState
    let run: RunResult
    let cfg: AgentConfig
    let lane: Int

    private var visibleTurns: [Turn] {
        app.prefs.showThinking ? run.turns : run.turns.filter { $0.kind != .think }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AgentTag(agentId: cfg.agentId, model: cfg.model, lane: lane)
                Spacer(minLength: 8)
                statusView
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(Theme.panel2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            // Eager VStack (not Lazy): a LazyVStack nested in this HStack-of-columns
            // re-estimates its height as rows realize during scroll, so the total
            // content height — and the scrollbar thumb — jumps and stutters. The
            // rows here are mostly cheap text (tool/think/user); the only heavy bit
            // is the few WKWebView answer previews, and those are already deferred
            // per-card (mountPreview), so building eagerly stays cheap and the
            // measured height is stable → smooth scrolling.
            VStack(alignment: .leading, spacing: 12) {
                if let err = run.error, run.status == .failed {
                    Text(err).font(Theme.mono(11.5)).foregroundStyle(Theme.bad)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11).background(Theme.delBG)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                }
                if visibleTurns.isEmpty && run.error == nil {
                    EmptyState(icon: "read", title: "无转录记录",
                               message: app.prefs.showThinking ? "这次运行没有产生可显示的对话步骤"
                                                               : "仅有推理步骤，已在设置中隐藏")
                }
                ForEach(visibleTurns) { turn in
                    ArchiveTurnView(turn: turn, cfg: cfg, run: run, lane: lane)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
        // No cardShadow here: this column spans the full conversation height, so a
        // shadow over its bounds rasterizes a huge offscreen layer on every scroll
        // frame. The hairline border carries the separation instead.
    }

    @ViewBuilder private var statusView: some View {
        switch run.status {
        case .done:
            HStack(spacing: 6) {
                SFIcon(name: "check", size: 12)
                Text("完成 · \(Fmt.sec(run.metrics.latencyMs))").font(Theme.mono(11.5, .semibold))
            }.foregroundStyle(Theme.good)
        case .failed:
            HStack(spacing: 6) { SFIcon(name: "warn", size: 12); Text("失败").font(Theme.mono(11.5, .semibold)) }
                .foregroundStyle(Theme.bad)
        case .running:
            Text("中断").font(Theme.mono(11.5)).foregroundStyle(Theme.ink3)
        case .pending:
            Text("未运行").font(Theme.mono(11.5)).foregroundStyle(Theme.ink3)
        }
    }
}

// A single archived turn. Reuses the pure ToolChip/FileRow; think/user are inlined;
// answers use a read-only artifact card with local (non-live) tab + trust state.
struct ArchiveTurnView: View {
    let turn: Turn
    let cfg: AgentConfig
    let run: RunResult
    let lane: Int

    var body: some View {
        switch turn.kind {
        case .think:  thinkView
        case .tool:   if let t = turn.tool { ToolChip(step: t) }
        case .answer: ArchiveAnswerCard(turn: turn, cfg: cfg, run: run, lane: lane)
        case .user:   userView
        }
    }

    private var userView: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("你").font(Theme.ui(11, .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(turn.summary).font(Theme.ui(13.5)).foregroundStyle(Theme.ink)
                .textSelection(.enabled)
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
            SFIcon(name: "brain", size: 13).foregroundStyle(Theme.ink3)
                .frame(width: 26, height: 26).background(Theme.panel2)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 7) {
                Text("推理").font(Theme.ui(10.5, .bold)).tracking(1.2).foregroundStyle(Theme.ink3)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(turn.plan.indices, id: \.self) { i in
                        HStack(alignment: .top, spacing: 7) {
                            Text("•").foregroundStyle(Theme.ink3)
                            Text(turn.plan[i]).font(Theme.ui(13)).foregroundStyle(Theme.ink2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// Read-only answer card with its own preview/code tab + trust state (does not touch app.live).
struct ArchiveAnswerCard: View {
    @EnvironmentObject var app: AppState
    let turn: Turn
    let cfg: AgentConfig
    let run: RunResult
    let lane: Int

    @State private var tab = "preview"
    @State private var localTrust = false
    // WKWebView is expensive to instantiate; with 3-4 lanes, mounting one per
    // answer synchronously on selection freezes the switch between history items.
    // Gate it behind a .task so the row commits first and the web view mounts a
    // runloop later (and only for cards actually built by the LazyVStack).
    @State private var mountPreview = false

    private var trusted: Bool { app.prefs.trustLocalPreviews || localTrust }
    // The artifact's HTML file may have been purged from the temp runs dir; only
    // offer "open in browser" / asset loading when it still exists on disk.
    private var fileStillOnDisk: Bool {
        guard let f = run.previewFileURL else { return false }
        return FileManager.default.fileExists(atPath: f.path)
    }
    // The lane's isolated workspace, if it still exists (purged for old archives).
    private var workdirURL: URL? {
        guard !run.workdir.isEmpty, FileManager.default.fileExists(atPath: run.workdir) else { return nil }
        return URL(fileURLWithPath: run.workdir)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentGlyph(agentId: cfg.agentId, lane: lane, box: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(turn.summary)
                    .font(Theme.ui(13.5)).foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15).padding(.vertical, 13)

                if !turn.files.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(turn.files) { f in FileRow(f: f, baseDir: run.workdir) }
                    }
                    .padding(.horizontal, 15).padding(.bottom, 13)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)
                }
                artifact
            }
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.r))
        }
    }

    private var artifact: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Segmented(view: $tab)   // shared control: doesn't squish in narrow columns
                Spacer(minLength: 6)
                Text(tab == "code" ? "\(turn.code.components(separatedBy: "\n").count) 行"
                                   : (turn.previewHTML == nil ? "无可渲染预览" : "渲染产物"))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                if let wd = workdirURL {
                    Button { FinderOpen.reveal(wd) } label: { SFIcon(name: "folder", size: 13).foregroundStyle(Theme.ink3) }
                        .buttonStyle(.plain).help("在 Finder 中打开产物文件夹").padding(.leading, 8)
                }
                if turn.previewHTML != nil, fileStillOnDisk {
                    Button {
                        if let f = run.previewFileURL {
                            NSWorkspace.shared.open(PreviewServer.shared.url(forFile: f) ?? f)
                        }
                    } label: { SFIcon(name: "browser", size: 13).foregroundStyle(Theme.ink3) }
                        .buttonStyle(.plain).help("在浏览器打开").padding(.leading, 8)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.panel2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            Group {
                if tab == "preview" {
                    if let html = turn.previewHTML {
                        if !mountPreview {
                            // lightweight stand-in; the web view mounts on the next
                            // runloop so selecting this history item stays snappy
                            VStack(spacing: 6) {
                                Spinner(size: 16)
                                Text("准备预览…").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
                            }
                            .frame(maxWidth: .infinity).frame(height: 300).background(Theme.panel2)
                            .task { mountPreview = true }
                        } else {
                        ZStack(alignment: .bottom) {
                            HTMLPreview(html: html,
                                        baseDir: fileStillOnDisk ? run.previewBaseDir : nil,
                                        fileURL: fileStillOnDisk ? run.previewFileURL : nil,
                                        readAccessDir: fileStillOnDisk ? run.workdir : nil,
                                        trusted: trusted)
                            if !trusted {
                                HStack(spacing: 8) {
                                    SFIcon(name: "warn", size: 12).foregroundStyle(Theme.ink2)
                                    Text("未信任 · 脚本/资源/网络已禁用").font(Theme.ui(11.5)).foregroundStyle(Theme.ink2)
                                    Spacer(minLength: 8)
                                    Button { localTrust = true } label: {
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
                        .frame(height: 300)
                        }
                    } else {
                        VStack(spacing: 6) {
                            SFIcon(name: "info", size: 18).foregroundStyle(Theme.ink3)
                            Text("此任务无可视化预览").font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                            Text("切到「代码」查看 diff").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
                        }
                        .frame(maxWidth: .infinity).frame(height: 300).background(Theme.panel2)
                    }
                } else {
                    CodeView(text: turn.code).frame(height: 300)
                }
            }
        }
        .background(Theme.panel)
    }
}
