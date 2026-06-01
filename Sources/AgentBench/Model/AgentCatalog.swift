import Foundation

// A coding agent the user can wire up. `bin` is the CLI executable name.
struct AgentSpec: Identifiable, Hashable {
    var id: String          // stable id used in configs
    var name: String        // display name
    var vendor: String
    var glyph: String       // monochrome mark, matches prototype
    var bin: String         // CLI binary to look for on PATH
    var models: [String]    // fallback suggestions only (real list is detected at runtime)
    var installHint: String // shown when the CLI is missing
    var hasStructuredJSON: Bool  // true → we parse rich turns/metrics
    var recipe: AgentRecipe? = nil  // non-nil → config-driven agent (from agents.json)

    var defaultModel: String { models.first ?? "" }
    var isCustom: Bool { recipe != nil }
}

// Declarative command/parse recipe for a user-defined agent.
struct AgentRecipe: Hashable {
    var parser: String              // claude | codex | opencode | text
    var args: [String]
    var modelArgs: [String]
    var autoApproveArgs: [String]
    var resumeArgs: [String]
    var resumeModelArgs: [String]
    var env: [String: String] = [:]  // per-agent env (base_url/token) injected at run
}

enum AgentCatalog {
    // built-ins + user-defined (agents.json); reload() refreshes after edits.
    static var all: [AgentSpec] = builtin
    static let builtin: [AgentSpec] = [
        AgentSpec(
            id: "claude-code", name: "Claude Code", vendor: "Anthropic", glyph: "✳",
            bin: "claude",
            models: ["sonnet", "opus", "haiku", "claude-sonnet-4-6", "claude-opus-4-8"],
            installHint: "npm i -g @anthropic-ai/claude-code  (或 https://claude.com/claude-code)",
            hasStructuredJSON: true),
        AgentSpec(
            id: "codex", name: "Codex", vendor: "OpenAI", glyph: "◆",
            bin: "codex",
            // ChatGPT-account 登录通常只放行 gpt-5.5；gpt-5.x-codex 多被拒。
            models: ["gpt-5.5", "gpt-5.5-codex", "gpt-5.1-codex"],
            installHint: "npm i -g @openai/codex@latest  (gpt-5.5 需 codex ≥ 0.135)",
            hasStructuredJSON: true),
        AgentSpec(
            id: "opencode", name: "OpenCode", vendor: "OSS", glyph: "◐",
            bin: "opencode",
            models: [],  // discovered at runtime via `opencode models` (provider/model)
            installHint: "curl -fsSL https://opencode.ai/install | bash  (或 brew install sst/tap/opencode)",
            hasStructuredJSON: true),
        AgentSpec(
            id: "gemini", name: "Gemini CLI", vendor: "Google", glyph: "✦",
            bin: "gemini",
            models: ["gemini-2.5-pro", "gemini-2.5-flash"],
            installHint: "npm i -g @google/gemini-cli",
            hasStructuredJSON: false),
        AgentSpec(
            id: "cursor", name: "Cursor Agent", vendor: "Cursor", glyph: "▷",
            bin: "cursor-agent",
            models: ["composer-1", "gpt-5", "claude-sonnet-4-5"],
            installHint: "curl https://cursor.com/install -fsS | bash",
            hasStructuredJSON: false),
        AgentSpec(
            id: "aider", name: "Aider", vendor: "OSS", glyph: "◇",
            bin: "aider",
            models: ["sonnet", "gpt-5", "deepseek"],
            installHint: "python -m pip install aider-install && aider-install",
            hasStructuredJSON: false),
    ]

    static func spec(_ id: String) -> AgentSpec {
        all.first(where: { $0.id == id }) ?? all.first ?? builtin[0]
    }

    // Merge built-ins with user agents. A user agent with the same id overrides.
    static func reload() {
        let user = AgentConfigFile.load()
        var merged = builtin
        for u in user {
            if let i = merged.firstIndex(where: { $0.id == u.id }) { merged[i] = u }
            else { merged.append(u) }
        }
        all = merged
    }
}
