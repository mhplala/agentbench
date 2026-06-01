import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var prefs = Prefs.shared
    @State private var showAssistant = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                section("外观") {
                    row("强调色") {
                        HStack(spacing: 8) {
                            ForEach(Theme.accentChoices, id: \.self) { hex in
                                let s = String(format: "#%06X", hex)
                                Button { prefs.accent = s } label: {
                                    Circle().fill(Color(hex: hex)).frame(width: 26, height: 26)
                                        .overlay(Circle().stroke(prefs.accent.lowercased() == s.lowercased() ? Theme.ink : Theme.line3,
                                                 lineWidth: prefs.accent.lowercased() == s.lowercased() ? 2 : 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }

                section("对话") {
                    row("显示推理过程") { Toggle("", isOn: $prefs.showThinking).labelsHidden() }
                }

                section("运行") {
                    row("自动批准 agent 改文件") {
                        Toggle("", isOn: $prefs.autoApprove).labelsHidden()
                    }
                    Text("对完全非交互的 agent（如 codex / aider）此项不生效——它们总是自动应用改动；是否限制写入范围由下方「沙盒运行」控制。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    row("沙盒运行（限制写入范围）") {
                        Toggle("", isOn: $prefs.sandboxRuns).labelsHidden()
                    }
                    Text("开启后用沙盒约束每次运行：codex 用其原生 workspace-write 沙盒；其余 agent 用 macOS sandbox-exec 包裹——可读全盘、可联网、可执行命令，但写入只允许工作副本、临时目录和各 CLI 的缓存/配置目录，碰不到你的其它文件。若某些 agent 在沙盒下异常可关闭。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("每次对比都在工作目录的隔离副本中运行，agent 的改动不会影响你的真实仓库；两个 agent 互不干扰。关闭后不再把写入限制在工作副本内，agent 可写其它位置，风险更高。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    row("自动回答 agent 的提问") {
                        Toggle("", isOn: $prefs.autoAnswerQuestions).labelsHidden()
                    }
                    Text("当某一轮以提问结尾（如「你想要哪种方案?」），自动回复「你决定」让它继续推进，最多连续自动应答 3 轮。关闭则需你在底部输入栏手动回复。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("预览") {
                    row("默认信任本地产物预览") {
                        Toggle("", isOn: $prefs.trustLocalPreviews).labelsHidden()
                    }
                    Text("开启后，预览直接渲染 agent 产出的 HTML 并运行其脚本、加载同目录 CSS/图片（用于看真实效果）。关闭则默认禁用脚本/资源/网络，需在每个预览上手动点「信任并运行」——更安全，适合对不信任的产物逐一确认。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("环境") {
                    ForEach(app.availabilities) { a in
                        HStack(spacing: 10) {
                            Text(a.spec.glyph).font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.spec.name).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                                Text(a.installed ? (a.path ?? "") : "未安装 · \(a.spec.installHint)")
                                    .font(Theme.mono(11)).foregroundStyle(a.installed ? Theme.ink3 : Theme.bad)
                                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if a.installed { SFIcon(name: "check", size: 13).foregroundStyle(Theme.good) }
                        }
                        .padding(.vertical, 6)
                    }
                    Button { app.bootstrap() } label: {
                        HStack(spacing: 6) { SFIcon(name: "refresh", size: 12); Text("重新检测").font(Theme.ui(12.5, .semibold)) }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.panel2)
                            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                    }.buttonStyle(.plain)
                }

                section("元 Agent · 裁判 & 配置助手") {
                    Text("评判和配置助手使用的“元 agent”，与参赛 agent 独立——它用自己的身份/模型/provider，不和被对比的 agent 混用额度，也避免“拿参赛选手当裁判”。留空模型 = 用该 agent 默认；provider 选默认 = 用其登录态。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    MetaAgentPicker()
                }

                section("Agent 配置（可扩展）") {
                    Text("内置 claude / codex / opencode 有最完整的解析。要加新 agent（如 Kimi），编辑 agents.json：声明 CLI、命令模板（占位符 {task} {model} {workdir} {message} {sessionId}）和使用哪个解析器（claude/codex/opencode/text）。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AgentConfigFile.url.path).font(Theme.mono(11)).foregroundStyle(Theme.ink2)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 10) {
                        Button { showAssistant = true } label: { settingBtn("spark", "配置助手（用 agent 帮你配）") }.buttonStyle(.plain)
                        Button {
                            AgentConfigFile.writeTemplateIfMissing()
                            NSWorkspace.shared.open(AgentConfigFile.url)
                        } label: { settingBtn("edit", "打开 agents.json") }.buttonStyle(.plain)
                        Button { app.reloadAgents() } label: { settingBtn("refresh", "重新加载") }.buttonStyle(.plain)
                    }
                    Text("已加载 agent：" + AgentCatalog.all.map { $0.name + ($0.isCustom ? "*" : "") }.joined(separator: " · ") + "（* = 自定义）")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("运行环境变量") {
                    Text("注入到每次 agent 运行的环境变量。常用于 provider 配置里 env_key 引用、但 GUI 环境缺失的 key——比如火山 ark 的 ARK_API_KEY 或 OPENAI_API_KEY。")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    CustomEnvEditor()
                }

                section("数据") {
                    Text("历史会话保存在：").font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                        + Text(Store.sessionsURL.path).font(Theme.mono(11)).foregroundStyle(Theme.ink2)
                }

                }
                .frame(maxWidth: 680).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40).padding(.vertical, 32)
            }
        }
        .background(Theme.bg)
        .onExitCommand { app.selectLive() }
        .sheet(isPresented: $showAssistant) {
            ConfigAssistantView().environmentObject(app)
        }
    }

    // Always-visible header so closing settings never requires scrolling to the bottom.
    private var header: some View {
        HStack {
            Text("设置").font(Theme.ui(20, .bold)).tracking(-0.3).foregroundStyle(Theme.ink)
            Spacer()
            Button { app.selectLive() } label: {
                HStack(spacing: 6) { SFIcon(name: "x", size: 12); Text("完成").font(Theme.ui(13, .semibold)) }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            }
            .buttonStyle(.plain).help("返回（Esc）")
        }
        .padding(.horizontal, 40).padding(.vertical, 14)
        .background(Theme.panel.opacity(0.95))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .bottom)
    }

    private func settingBtn(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 6) { SFIcon(name: icon, size: 12); Text(label).font(Theme.ui(12.5, .semibold)) }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.panel2)
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BlockLabel(text: title)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
    }

    @ViewBuilder private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).font(Theme.ui(13.5)).foregroundStyle(Theme.ink)
            Spacer()
            content()
        }
    }
}

// Editable list of custom env vars injected into every agent run.
struct CustomEnvEditor: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var rows: [Row] = []
    struct Row: Identifiable { let id = UUID(); var key: String; var value: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($rows) { $r in
                HStack(spacing: 8) {
                    TextField("KEY（如 ARK_API_KEY）", text: $r.key)
                        .textFieldStyle(.plain).font(Theme.mono(12.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.panel2)
                        .overlay(RoundedRectangle(cornerRadius: Theme.rXs).stroke(Theme.line3, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
                        .frame(width: 200)
                    SecureField("value", text: $r.value)
                        .textFieldStyle(.plain).font(Theme.mono(12.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.panel2)
                        .overlay(RoundedRectangle(cornerRadius: Theme.rXs).stroke(Theme.line3, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
                        .frame(maxWidth: .infinity)
                    Button { rows.removeAll { $0.id == r.id }; commit() } label: {
                        SFIcon(name: "x", size: 12).foregroundStyle(Theme.ink3)
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Button { rows.append(Row(key: "", value: "")) } label: {
                    HStack(spacing: 5) { SFIcon(name: "plus", size: 11); Text("添加变量").font(Theme.ui(12.5, .semibold)) }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.panel2)
                        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                }.buttonStyle(.plain)
                Button { commit() } label: {
                    Text("保存").font(Theme.ui(12.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color(hexString: prefs.accent)).clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                }.buttonStyle(.plain)
            }
        }
        .onAppear {
            rows = prefs.customEnv.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) }
            if rows.isEmpty { rows = [Row(key: "", value: "")] }
        }
    }

    private func commit() {
        var dict: [String: String] = [:]
        for r in rows {
            let k = r.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { dict[k] = r.value }
        }
        prefs.customEnv = dict
    }
}
