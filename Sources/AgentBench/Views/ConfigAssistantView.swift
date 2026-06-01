import SwiftUI

@MainActor
final class ConfigAssistantModel: ObservableObject {
    @Published var turns: [Turn] = []
    @Published var running = false
    @Published var proposal: ConfigAssistant.Proposal?
    @Published var applied = false
    @Published var verifying = false
    @Published var verifyResults: [ConfigAssistant.VerifyResult] = []

    func run(request: String, agentId: String, bin: String, sandbox: Bool,
             model: String, env: [String: String]) {
        running = true; proposal = nil; applied = false; turns = []; verifyResults = []
        let current = (try? String(contentsOf: AgentConfigFile.url, encoding: .utf8)) ?? AgentConfigFile.template
        Task {
            let p = await ConfigAssistant.run(request: request, currentJSON: current,
                                              agentId: agentId, bin: bin, sandbox: sandbox,
                                              model: model, env: env) { ts in
                Task { @MainActor in self.turns = ts }
            }
            self.running = false
            self.proposal = p
        }
    }

    func verify(_ json: String, env: [String: String]) {
        verifying = true; verifyResults = []
        Task { let r = await ConfigAssistant.verify(json, env: env); self.verifying = false; self.verifyResults = r }
    }
}

// "用 agent 帮你配" — the agent streams its reasoning + tool-use (it actually tests
// CLIs while configuring), proposes agents.json, you verify + apply.
struct ConfigAssistantView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = ConfigAssistantModel()
    @State private var request = ""

    // use the configured meta agent; fall back to first installed if it's missing
    private var agent: (id: String, bin: String)? {
        if let bin = app.metaBin { return (app.prefs.metaAgentId, bin) }
        return ConfigAssistant.defaultAgent(app.availabilities)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                SFIcon(name: "spark", size: 16).foregroundStyle(Theme.ink)
                Text("配置助手").font(Theme.ui(15, .bold)).foregroundStyle(Theme.ink)
                if let a = agent {
                    Text("用 \(AgentCatalog.spec(a.id).name)").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.panel2).overlay(Capsule().stroke(Theme.line2, lineWidth: 1)).clipShape(Capsule())
                }
                Spacer()
                Button { dismiss() } label: { SFIcon(name: "x", size: 16).foregroundStyle(Theme.ink3) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("用一句话说你想怎么配。助手会**实际调用工具测试**（查 CLI、看 --help、跑最小命令）边测边定，再改写 agents.json，你确认后应用。例如：「加一个 Kimi，bin 是 kimi」「给 codex 加 gpt-5.5 模型建议」。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $request)
                        .font(Theme.ui(14)).scrollContentBackground(.hidden)
                        .frame(minHeight: 64)
                        .padding(10)
                        .background(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))

                    if agent == nil {
                        Text("没有检测到可用的 agent CLI，无法运行助手。请先安装并登录 claude / codex / opencode 之一。")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.bad)
                    }

                    HStack {
                        Button { runIt() } label: {
                            HStack(spacing: 7) {
                                if m.running { Spinner(size: 12) } else { SFIcon(name: "play", size: 12) }
                                Text(m.running ? "运行中…" : "运行助手").font(Theme.ui(13, .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(canRun ? app.accentColor : Theme.ink3)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                        }
                        .buttonStyle(.plain).disabled(!canRun)
                        Spacer()
                    }

                    // live transcript (reasoning / tool-use / answer)
                    if !m.turns.isEmpty {
                        AssistantTranscript(turns: m.turns, working: m.running)
                    }

                    if let p = m.proposal {
                        if let err = p.error {
                            label("warn", err, Theme.bad)
                        } else if let json = p.proposedJSON {
                            label("check", "提议配置 · \(p.agentCount) 个自定义 agent", Theme.ink3)
                            if !p.env.isEmpty {
                                label("info", "将写入运行环境变量：" + p.env.keys.sorted().joined(separator: ", "), Theme.ink2)
                            }
                            CodeView(text: json).frame(height: 200)
                                .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line2, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                            HStack(spacing: 10) {
                                Button { m.verify(json, env: p.env) } label: {
                                    HStack(spacing: 6) {
                                        if m.verifying { Spinner(size: 11) } else { SFIcon(name: "bolt", size: 12) }
                                        Text(m.verifying ? "测试中…" : "测试配置").font(Theme.ui(13, .semibold))
                                    }
                                    .foregroundStyle(Theme.ink).padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(Theme.panel2)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                                }.buttonStyle(.plain).disabled(m.verifying)
                                Button { apply(json) } label: {
                                    HStack(spacing: 6) { SFIcon(name: "check", size: 12); Text("应用并重载").font(Theme.ui(13, .semibold)) }
                                        .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 9)
                                        .background(app.accentColor).clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                                }.buttonStyle(.plain)
                                if m.applied { label("check", "已应用并重载", Theme.good) }
                            }
                            ForEach(m.verifyResults) { r in
                                label(r.ok ? "check" : "warn", "\(r.name)：\(r.detail)", r.ok ? Theme.good : Theme.bad)
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 680, height: 640)
        .background(Theme.bg)
    }

    private var canRun: Bool { agent != nil && !m.running && !request.trimmingCharacters(in: .whitespaces).isEmpty }

    private func runIt() {
        guard let a = agent else { return }
        let model = a.id == app.prefs.metaAgentId ? app.prefs.metaModel : ""
        m.run(request: request, agentId: a.id, bin: a.bin, sandbox: app.prefs.sandboxRuns,
              model: model, env: app.metaEnv())
    }
    private func apply(_ json: String) {
        do {
            try ConfigAssistant.apply(json)
            if let env = m.proposal?.env, !env.isEmpty {   // AI-provided env vars → runtime env
                var merged = app.prefs.customEnv
                for (k, v) in env where !k.isEmpty { merged[k] = v }
                app.prefs.customEnv = merged
            }
            app.reloadAgents(); m.applied = true
        } catch { m.proposal?.error = "写入失败: \(error.localizedDescription)" }
    }
    private func label(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            SFIcon(name: icon, size: 11).foregroundStyle(color)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// Renders the assistant's run as a chat-like transcript (reasoning · tool chips · answer).
struct AssistantTranscript: View {
    let turns: [Turn]
    var working: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(turns) { t in
                switch t.kind {
                case .think:
                    if !t.plan.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("推理").font(Theme.ui(10, .bold)).tracking(1.1).foregroundStyle(Theme.ink3)
                            ForEach(t.plan.indices, id: \.self) { i in
                                Text("• " + t.plan[i]).font(Theme.ui(12.5)).foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .tool:
                    if let step = t.tool { ToolChip(step: step) }
                case .answer, .user:
                    Text(t.summary).font(Theme.mono(11.5)).foregroundStyle(Theme.ink)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Theme.panel2)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
                }
            }
            if working { HStack(spacing: 8) { Spinner(size: 12); TypingDots() } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
    }
}
