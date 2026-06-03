import SwiftUI

// Two protocols cover almost every relay: Anthropic-compatible (driven by the claude
// CLI) and OpenAI-compatible (driven by codex via the in-app Responses→chat proxy).
enum QuickProtocol: String, CaseIterable, Identifiable {
    case openai, anthropic
    var id: String { rawValue }
    var label: String { self == .anthropic ? "Anthropic 兼容" : "OpenAI 兼容" }
    var engine: String { self == .anthropic ? "claude CLI" : "codex CLI" }
    var glyph: String { self == .anthropic ? "✳" : "◆" }
    var urlHint: String {
        self == .anthropic ? "Anthropic 兼容端点（常以 /anthropic 或 /v1 结尾）"
                           : "OpenAI 兼容端点（常以 /v1 结尾，提供 /chat/completions）"
    }
    var note: String {
        self == .anthropic ? "用 claude CLI 驱动；自动注入 BASE_URL/TOKEN + --bare，并把 sonnet/opus/haiku 别名映射到你填的模型。"
                           : "用 codex CLI 驱动；codex 只会 Responses 协议，会自动经内置本地代理转成上游的 chat/completions。"
    }
}

// Builds an agents.json entry from {protocol, key, url, models} — the same recipes
// that make xiaomi / 豆包 work, without hand-editing JSON.
enum QuickProvider {
    static func slug(_ s: String) -> String {
        var id = String(s.lowercased().map { $0.isLetter || $0.isNumber ? Character($0.lowercased()) : "-" })
        while id.contains("--") { id = id.replacingOccurrences(of: "--", with: "-") }
        id = id.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return id.isEmpty ? "provider" : id
    }

    static func make(proto: QuickProtocol, name: String, baseURL: String, key: String, models: [String]) -> UserAgent {
        let id = slug(name)
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch proto {
        case .anthropic:
            var env = ["ANTHROPIC_BASE_URL": url, "ANTHROPIC_AUTH_TOKEN": tok]
            if let first = models.first {     // map aliases so it works even with no --model
                env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = first
                env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = first
                env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = first
            }
            return UserAgent(
                id: id, name: name, vendor: "Custom", glyph: "✳", bin: "claude",
                models: models, installHint: "npm i -g @anthropic-ai/claude-code",
                parser: "claude",
                args: ["-p", "{task}", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions", "--bare"],
                modelArgs: ["--model", "{model}"], autoApproveArgs: nil,
                resumeArgs: ["--resume", "{sessionId}", "-p", "{message}", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions", "--bare"],
                resumeModelArgs: nil, env: env)
        case .openai:
            return UserAgent(
                id: id, name: name, vendor: "Custom", glyph: "◆", bin: "codex",
                models: models, installHint: "npm i -g @openai/codex",
                parser: "codex",
                args: ["exec", "{task}", "--json", "-C", "{workdir}", "--skip-git-repo-check"],
                modelArgs: ["-m", "{model}"], autoApproveArgs: nil,
                resumeArgs: ["exec", "resume", "--last", "{message}", "--json", "--skip-git-repo-check", "-C", "{workdir}"],
                resumeModelArgs: ["-m", "{model}"],
                env: ["OPENAI_BASE_URL": url, "OPENAI_API_KEY": tok])
        }
    }
}

struct ProviderQuickAddView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var proto: QuickProtocol = .openai
    @State private var name = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var models = ""    // 逗号分隔

    private var modelList: [String] {
        models.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var canSave: Bool {
        ![name, baseURL, key].contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            && !modelList.isEmpty
    }
    private var binInstalled: Bool { app.isInstalled(proto == .anthropic ? "claude-code" : "codex") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加 Provider").font(Theme.ui(16, .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { dismiss() } label: { SFIcon(name: "x", size: 15).foregroundStyle(Theme.ink3) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 15)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // protocol
                    field("协议") {
                        Picker("", selection: $proto) {
                            ForEach(QuickProtocol.allCases) { p in Text(p.label).tag(p) }
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                    HStack(spacing: 6) {
                        SFIcon(name: "info", size: 11).foregroundStyle(Theme.ink3)
                        Text("\(proto.engine) · \(proto.note)")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                    if !binInstalled {
                        Text("⚠️ 未检测到 \(proto.engine)，安装后才能运行。")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.bad)
                    }

                    field("名称") { tf("如 Xiaomi / 豆包 / MyRelay", $name) }
                    field("Base URL") {
                        VStack(alignment: .leading, spacing: 4) {
                            tf("https://…", $baseURL)
                            Text(proto.urlHint).font(Theme.ui(11)).foregroundStyle(Theme.ink3)
                        }
                    }
                    field("API Key") { SecureField("sk-… / tp-… / ark-…", text: $key).textFieldStyle(.plain).font(Theme.mono(12.5)).padding(10).panelBox() }
                    field("模型") {
                        VStack(alignment: .leading, spacing: 4) {
                            tf("逗号分隔，如 mimo-v2.5-pro, mimo-v2.5", $models)
                            Text("第一个为默认模型。").font(Theme.ui(11)).foregroundStyle(Theme.ink3)
                        }
                    }

                    Text("凭证只写入本机 \(AgentConfigFile.url.lastPathComponent)，不会上传。")
                        .font(Theme.ui(11)).foregroundStyle(Theme.ink3).padding(.top, 2)
                }
                .padding(20)
            }

            HStack(spacing: 10) {
                Spacer()
                Button { dismiss() } label: {
                    Text("取消").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Theme.panel).overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                }.buttonStyle(.plain)
                Button { save() } label: {
                    Text("添加并启用").font(Theme.ui(13, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(canSave ? app.accentColor : Theme.ink3)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                }.buttonStyle(.plain).disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .top)
        }
        .frame(width: 520, height: 560)
        .background(Theme.bg)
        .environment(\.colorScheme, .light)
    }

    private func save() {
        AgentConfigFile.upsert(QuickProvider.make(proto: proto, name: name, baseURL: baseURL, key: key, models: modelList))
        app.reloadAgents()
        dismiss()
    }

    @ViewBuilder private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(Theme.ui(11.5, .bold)).tracking(0.6).foregroundStyle(Theme.ink3)
            content()
        }
    }
    private func tf(_ ph: String, _ text: Binding<String>) -> some View {
        TextField(ph, text: text).textFieldStyle(.plain).font(Theme.ui(13.5))
            .padding(10).panelBox()
    }
}

private extension View {
    func panelBox() -> some View {
        background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
    }
}
