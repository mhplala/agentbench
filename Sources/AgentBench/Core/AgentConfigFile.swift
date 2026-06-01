import Foundation

// User-editable agent definitions loaded from
// ~/Library/Application Support/AgentBench/agents.json
//
// Lets you add new agents (Kimi, any CLI…) without recompiling: declare the
// binary, command templates with placeholders, and which built-in parser to use.
//
// Placeholders: {task} {message} {model} {workdir} {sessionId}
//   - put model flags in "modelArgs" (added only when a model is chosen)
//   - put auto-approve flags in "autoApproveArgs" (added when auto-approve is on)
//   - "resumeArgs" enables multi-turn; reference {sessionId}/{message}; omit to
//     fall back to a stateless re-run on the same workspace.
struct UserAgentsFile: Codable {
    var agents: [UserAgent]
}

struct UserAgent: Codable {
    var id: String
    var name: String
    var vendor: String?
    var glyph: String?
    var bin: String
    var models: [String]?
    var installHint: String?
    var parser: String?            // "claude" | "codex" | "opencode" | "text" (default)
    var args: [String]
    var modelArgs: [String]?
    var autoApproveArgs: [String]?
    var resumeArgs: [String]?
    var resumeModelArgs: [String]?
    var env: [String: String]?     // per-agent env (e.g. ANTHROPIC_BASE_URL/AUTH_TOKEN)
}

enum AgentConfigFile {
    static var url: URL { Store.dir.appendingPathComponent("agents.json") }

    static func load() -> [AgentSpec] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(UserAgentsFile.self, from: data) else { return [] }
        return file.agents.map(spec(from:))
    }

    static func spec(from u: UserAgent) -> AgentSpec {
        AgentSpec(
            id: u.id, name: u.name, vendor: u.vendor ?? "Custom",
            glyph: u.glyph?.isEmpty == false ? u.glyph! : "◆",
            bin: u.bin, models: u.models ?? [],
            installHint: u.installHint ?? "请确保 \(u.bin) 已在 PATH 中",
            hasStructuredJSON: (u.parser ?? "text") != "text",
            recipe: AgentRecipe(
                parser: u.parser ?? "text",
                args: u.args,
                modelArgs: u.modelArgs ?? [],
                autoApproveArgs: u.autoApproveArgs ?? [],
                resumeArgs: u.resumeArgs ?? [],
                resumeModelArgs: u.resumeModelArgs ?? (u.modelArgs ?? []),
                env: u.env ?? [:]
            ))
    }

    static func parse(_ json: String) -> [UserAgent] {
        guard let data = json.data(using: .utf8),
              let file = try? JSONDecoder().decode(UserAgentsFile.self, from: data) else { return [] }
        return file.agents
    }

    // Write a commented example (with Kimi) the first time, so the format is discoverable.
    static func writeTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? template.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func ensureTemplate() { try? template.data(using: .utf8)?.write(to: url, options: .atomic) }

    static let template = """
    {
      "_说明": "在 agents 数组里添加你自己的 agent。占位符: {task} {message} {model} {workdir} {sessionId}。parser 可选 claude/codex/opencode/text。改完在 设置→Agent 配置 点「重新加载」。",
      "agents": [
        {
          "id": "kimi",
          "name": "Kimi",
          "vendor": "Moonshot",
          "glyph": "🌙",
          "bin": "kimi",
          "models": ["kimi-k2", "kimi-k2-turbo"],
          "installHint": "npm i -g @moonshot/kimi-cli  (示例，按实际安装方式)",
          "parser": "text",
          "args": ["-p", "{task}", "--cwd", "{workdir}"],
          "modelArgs": ["--model", "{model}"],
          "autoApproveArgs": ["--yes"],
          "resumeArgs": ["-p", "{message}", "--cwd", "{workdir}", "--continue"]
        }
      ]
    }
    """
}
