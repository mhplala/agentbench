import Foundation

// Accumulates parsed signal from an agent's output stream.
struct RunAccumulator {
    var reasoning: [String] = []
    var tools: [ToolStep] = []
    var answerText: String = ""
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var cost: Double? = nil
    var turns: Int = 0
    var durationMs: Int? = nil
    var sawStructuredTokens = false
    var rawLines: [String] = []
    var errorMessage: String? = nil   // surfaced run failure reason (e.g. model not supported)
    var sessionId: String? = nil      // CLI session/thread id for multi-turn resume

    mutating func addTool(_ kind: ToolKind, _ label: String, _ detail: String) {
        // de-dupe consecutive identical chips
        if let last = tools.last, last.kind == kind, last.label == label, last.detail == detail { return }
        tools.append(ToolStep(kind: kind, label: label, detail: detail))
    }
}

protocol AgentAdapter {
    var spec: AgentSpec { get }
    func command(task: String, model: String, workdir: String, autoApprove: Bool) -> [String]
    // Continue an existing conversation. Default: stateless re-run in the same
    // workdir (file state carries the progress); override for real session resume.
    func resumeArgs(message: String, model: String, workdir: String, sessionId: String?, autoApprove: Bool) -> [String]
    func parse(_ line: ProcessRunner.Line, into acc: inout RunAccumulator)
}

extension AgentAdapter {
    // default resume: stateless re-run on the same (mutated) workdir
    func resumeArgs(message: String, model: String, workdir: String, sessionId: String?, autoApprove: Bool) -> [String] {
        command(task: message, model: model, workdir: workdir, autoApprove: autoApprove)
    }

    // default: treat every non-empty stdout line as answer text
    func parse(_ line: ProcessRunner.Line, into acc: inout RunAccumulator) {
        acc.rawLines.append((line.isErr ? "! " : "") + line.text)
        if line.isErr { return }
        let t = line.text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        acc.answerText += line.text + "\n"
    }
}

enum Adapters {
    static func make(_ id: String) -> AgentAdapter {
        let spec = AgentCatalog.spec(id)
        if let recipe = spec.recipe { return ConfigAdapter(spec: spec, recipe: recipe) }
        switch id {
        case "claude-code": return ClaudeCodeAdapter()
        case "codex":       return CodexAdapter()
        case "opencode":    return OpenCodeAdapter()
        default:            return PlainAdapter(spec: spec)
        }
    }

    // parser instance for a recipe's `parser` field
    static func parser(_ name: String, spec: AgentSpec) -> AgentAdapter {
        switch name {
        case "claude":   return ClaudeCodeAdapter()
        case "codex":    return CodexAdapter()
        case "opencode": return OpenCodeAdapter()
        default:         return PlainAdapter(spec: spec)
        }
    }
}

// Drives a user-defined agent: builds args from templates and parses output with
// one of the built-in parsers.
struct ConfigAdapter: AgentAdapter {
    let spec: AgentSpec
    let recipe: AgentRecipe
    private var inner: AgentAdapter { Adapters.parser(recipe.parser, spec: spec) }

    func command(task: String, model: String, workdir: String, autoApprove: Bool) -> [String] {
        let m = model.isEmpty ? spec.defaultModel : model   // custom agents fall back to their first model
        var a = subst(recipe.args, task: task, message: task, model: m, workdir: workdir, sessionId: nil)
        if !m.isEmpty { a += subst(recipe.modelArgs, task: task, message: task, model: m, workdir: workdir, sessionId: nil) }
        if autoApprove { a += recipe.autoApproveArgs }
        return a
    }

    func resumeArgs(message: String, model: String, workdir: String, sessionId: String?, autoApprove: Bool) -> [String] {
        let m = model.isEmpty ? spec.defaultModel : model
        guard !recipe.resumeArgs.isEmpty else {
            return command(task: message, model: m, workdir: workdir, autoApprove: autoApprove)
        }
        var a = subst(recipe.resumeArgs, task: message, message: message, model: m, workdir: workdir, sessionId: sessionId)
        if !m.isEmpty { a += subst(recipe.resumeModelArgs, task: message, message: message, model: m, workdir: workdir, sessionId: sessionId) }
        if autoApprove { a += recipe.autoApproveArgs }
        return a
    }

    func parse(_ line: ProcessRunner.Line, into acc: inout RunAccumulator) {
        inner.parse(line, into: &acc)
    }

    private func subst(_ tokens: [String], task: String, message: String, model: String,
                       workdir: String, sessionId: String?) -> [String] {
        tokens.compactMap { tok in
            if model.isEmpty && tok.contains("{model}") { return nil }       // drop unset model tokens
            if sessionId == nil && tok.contains("{sessionId}") { return nil }
            return tok
                .replacingOccurrences(of: "{task}", with: task)
                .replacingOccurrences(of: "{message}", with: message)
                .replacingOccurrences(of: "{model}", with: model)
                .replacingOccurrences(of: "{workdir}", with: workdir)
                .replacingOccurrences(of: "{sessionId}", with: sessionId ?? "")
        }
    }
}

// MARK: - Claude Code (rich stream-json)

struct ClaudeCodeAdapter: AgentAdapter {
    let spec = AgentCatalog.spec("claude-code")

    func command(task: String, model: String, workdir: String, autoApprove: Bool) -> [String] {
        var a = ["-p", task, "--output-format", "stream-json", "--verbose"]
        if !model.isEmpty { a += ["--model", model] }
        a += autoApprove ? ["--dangerously-skip-permissions"] : ["--permission-mode", "acceptEdits"]
        return a
    }

    func resumeArgs(message: String, model: String, workdir: String, sessionId: String?, autoApprove: Bool) -> [String] {
        var a = ["-p", message, "--output-format", "stream-json", "--verbose"]
        if let sid = sessionId { a += ["--resume", sid] } else { a += ["--continue"] }
        if !model.isEmpty { a += ["--model", model] }
        a += autoApprove ? ["--dangerously-skip-permissions"] : ["--permission-mode", "acceptEdits"]
        return a
    }

    func parse(_ line: ProcessRunner.Line, into acc: inout RunAccumulator) {
        acc.rawLines.append((line.isErr ? "! " : "") + line.text)
        guard let obj = JSON.parse(line.text) else {
            if line.isErr, !line.text.isEmpty { /* stderr noise */ }
            return
        }
        if let sid = obj.str("session_id") { acc.sessionId = sid }
        switch obj.str("type") {
        case "assistant":
            guard let msg = obj.dict("message") else { return }
            if let usage = msg.dict("usage") {
                if let i = usage.int("input_tokens") { acc.tokensIn = max(acc.tokensIn, i); acc.sawStructuredTokens = true }
                if let o = usage.int("output_tokens") { acc.tokensOut = max(acc.tokensOut, o); acc.sawStructuredTokens = true }
            }
            for block in msg.arr("content") ?? [] {
                guard let b = block as? [String: Any] else { continue }
                switch b.str("type") {
                case "text":
                    if let s = b.str("text") { acc.answerText += s + "\n" }
                case "thinking":
                    if let s = b.str("thinking") ?? b.str("text") {
                        for ln in s.components(separatedBy: "\n") where !ln.trimmingCharacters(in: .whitespaces).isEmpty {
                            acc.reasoning.append(ln.trimmingCharacters(in: .whitespaces))
                        }
                    }
                case "tool_use":
                    let (kind, label, detail) = Self.tool(name: b.str("name") ?? "", input: b.dict("input") ?? [:])
                    acc.addTool(kind, label, detail)
                    acc.turns += 1
                default: break
                }
            }
        case "result":
            if let c = obj.dbl("total_cost_usd") { acc.cost = c }
            if let d = obj.int("duration_ms") { acc.durationMs = d }
            if let n = obj.int("num_turns") { acc.turns = max(acc.turns, n) }
            if let usage = obj.dict("usage") {
                if let i = usage.int("input_tokens") { acc.tokensIn = max(acc.tokensIn, i); acc.sawStructuredTokens = true }
                if let o = usage.int("output_tokens") { acc.tokensOut = max(acc.tokensOut, o); acc.sawStructuredTokens = true }
            }
            if let r = obj.str("result"), !r.isEmpty { acc.answerText = r + "\n" }
        default: break
        }
    }

    static func tool(name: String, input: [String: Any]) -> (ToolKind, String, String) {
        let path = (input.str("file_path") ?? input.str("path") ?? input.str("notebook_path") ?? "")
        let base = path.isEmpty ? "" : (path as NSString).lastPathComponent
        switch name {
        case "Read", "NotebookRead": return (.read, "读取 \(base)", path)
        case "Grep": return (.read, "搜索", input.str("pattern") ?? "")
        case "Glob": return (.read, "查找文件", input.str("pattern") ?? "")
        case "Edit", "MultiEdit": return (.edit, "编辑 \(base)", path)
        case "Write": return (.edit, "写入 \(base)", path)
        case "NotebookEdit": return (.edit, "编辑 \(base)", path)
        case "Bash":
            let cmd = input.str("command") ?? ""
            return (.shell, "运行", String(cmd.prefix(80)))
        case "TodoWrite": return (.info, "规划任务", "")
        case "Task": return (.info, "子任务", input.str("description") ?? "")
        case "WebFetch", "WebSearch": return (.read, "查询网络", input.str("url") ?? input.str("query") ?? "")
        case "ToolSearch": return (.info, "查找工具", input.str("query") ?? "")
        case "Skill": return (.info, "技能 " + (input.str("command") ?? input.str("name") ?? ""), "")
        default:
            // show the most useful input field as detail rather than a blank chip
            let detail = input.str("command") ?? input.str("query") ?? input.str("pattern")
                ?? input.str("description") ?? input.str("url") ?? input.str("prompt") ?? ""
            return (.info, name, String(detail.prefix(80)))
        }
    }
}

// MARK: - Codex (exec --json)

struct CodexAdapter: AgentAdapter {
    let spec = AgentCatalog.spec("codex")

    // ask reasoning models to surface a reasoning summary (no-op on models that don't
    // support it) so codex's thinking shows up in the 推理 stream
    private let reasoningArgs = ["-c", "model_reasoning_summary=\"auto\""]

    func command(task: String, model: String, workdir: String, autoApprove: Bool) -> [String] {
        var a = ["exec", task, "--json", "-C", workdir, "--skip-git-repo-check"] + reasoningArgs
        if !model.isEmpty { a += ["-m", model] }
        a += autoApprove ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--full-auto"]
        return a
    }

    func resumeArgs(message: String, model: String, workdir: String, sessionId: String?, autoApprove: Bool) -> [String] {
        var a = ["exec", "resume"]
        if let sid = sessionId { a += [sid] } else { a += ["--last"] }
        a += [message, "--json", "--skip-git-repo-check", "-C", workdir] + reasoningArgs
        if !model.isEmpty { a += ["-m", model] }
        a += autoApprove ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--full-auto"]
        return a
    }

    func parse(_ line: ProcessRunner.Line, into acc: inout RunAccumulator) {
        acc.rawLines.append((line.isErr ? "! " : "") + line.text)
        guard let obj = JSON.parse(line.text) else {
            if !line.isErr, !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                acc.answerText += line.text + "\n"
            }
            return
        }
        // Real `codex exec --json` schema: thread.started / turn.started /
        // item.{started,updated,completed} (item.type) / turn.completed / error / turn.failed
        let type = obj.str("type") ?? ""
        if type == "thread.started", let tid = obj.str("thread_id") { acc.sessionId = tid }
        switch type {
        case "error", "turn.failed":
            let raw = obj.str("message") ?? obj.dig("error", "message") ?? "运行失败"
            acc.errorMessage = Self.humanError(raw)
        case "turn.completed":
            if let u = obj.dict("usage") {
                if let i = u.int("input_tokens") ?? u.int("prompt_tokens") { acc.tokensIn = max(acc.tokensIn, i); acc.sawStructuredTokens = true }
                if let o = u.int("output_tokens") ?? u.int("completion_tokens") { acc.tokensOut = max(acc.tokensOut, o); acc.sawStructuredTokens = true }
            }
        case "item.started", "item.updated", "item.completed":
            guard let it = obj.dict("item") else { return }
            let itype = it.str("type") ?? it.str("item_type") ?? ""
            switch itype {
            case "reasoning":
                if type == "item.completed", let s = it.str("text") ?? it.str("content") {
                    acc.reasoning.append(contentsOf: s.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                }
            case "agent_message", "assistant_message", "message":
                if type == "item.completed", let s = it.str("text") ?? it.str("content") ?? it.str("message") {
                    acc.answerText += s + "\n"
                }
            case "command_execution", "command", "local_shell_call":
                if type != "item.completed" { return }
                let cmd = it.str("command")
                    ?? (it.arr("command")?.compactMap { $0 as? String }.joined(separator: " ")) ?? ""
                acc.addTool(.shell, "运行", String(cmd.prefix(80))); acc.turns += 1
            case "file_change", "patch_apply", "apply_patch":
                let path = it.str("path") ?? (it.arr("changes")?.first as? [String: Any])?.str("path") ?? ""
                let base = path.isEmpty ? "" : (path as NSString).lastPathComponent
                acc.addTool(.edit, base.isEmpty ? "改动文件" : "编辑 \(base)", path); acc.turns += 1
            case "mcp_tool_call", "tool_call":
                acc.addTool(.info, it.str("name") ?? "工具调用", ""); acc.turns += 1
            default:
                break
            }
        default:
            break
        }
    }

    // Codex wraps API errors as a JSON string inside `message`; pull out the human text.
    static func humanError(_ raw: String) -> String {
        if let o = JSON.parse(raw), let m = o.dig("error", "message") ?? o.str("message") { return m }
        return raw
    }
}

// MARK: - OpenCode (run --format json)

struct OpenCodeAdapter: AgentAdapter {
    let spec = AgentCatalog.spec("opencode")

    func command(task: String, model: String, workdir: String, autoApprove: Bool) -> [String] {
        var a = ["run", task, "--format", "json", "--dir", workdir, "--thinking"]   // emit reasoning
        if !model.isEmpty { a += ["-m", model] }
        return a
    }

    func resumeArgs(message: String, model: String, workdir: String, sessionId: String?, autoApprove: Bool) -> [String] {
        var a = ["run", message, "--format", "json", "--dir", workdir, "--thinking"]
        if let sid = sessionId { a += ["--session", sid] } else { a += ["--continue"] }
        if !model.isEmpty { a += ["-m", model] }
        return a
    }

    func parse(_ line: ProcessRunner.Line, into acc: inout RunAccumulator) {
        acc.rawLines.append((line.isErr ? "! " : "") + line.text)
        guard let obj = JSON.parse(line.text) else {
            if !line.isErr, !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                acc.answerText += line.text + "\n"
            }
            return
        }
        if let sid = obj.str("sessionID") ?? obj.str("session_id") ?? obj.dig("info", "id") ?? obj.dig("session", "id") {
            acc.sessionId = sid
        }
        let type = obj.str("type") ?? obj.dig("part", "type") ?? ""
        // text parts
        if type.contains("text"), let s = obj.str("text") ?? obj.dig("part", "text") {
            acc.answerText += s + "\n"
        }
        // tool parts — opencode nests under part.state.input
        if type.contains("tool") {
            let name = obj.str("tool") ?? obj.dig("part", "tool") ?? obj.str("name") ?? "tool"
            let input = (obj.dict("part")?.dict("state")?.dict("input"))
                ?? obj.dict("input") ?? obj.dig2("part", "input") ?? [:]
            let (k, l, d) = mapTool(name, input)
            acc.addTool(k, l, d); acc.turns += 1
        }
        // reasoning
        if type.contains("reasoning"), let s = obj.str("text") ?? obj.dig("part", "text") {
            acc.reasoning.append(s)
        }
        // usage / cost
        if let u = obj.dict("tokens") ?? obj.dict("usage") ?? obj.dig2("info", "tokens") {
            if let i = u.int("input") ?? u.int("input_tokens") { acc.tokensIn = max(acc.tokensIn, i); acc.sawStructuredTokens = true }
            if let o = u.int("output") ?? u.int("output_tokens") { acc.tokensOut = max(acc.tokensOut, o); acc.sawStructuredTokens = true }
        }
        if let c = obj.dbl("cost") ?? obj.dig2("info", "cost")?.dbl("total") { if c > 0 { acc.cost = c } }
    }

    private func mapTool(_ name: String, _ input: [String: Any]) -> (ToolKind, String, String) {
        let n = name.lowercased()
        let path = input.str("filePath") ?? input.str("path") ?? ""
        let base = path.isEmpty ? "" : (path as NSString).lastPathComponent
        // best detail from common input fields
        let detail = input.str("command") ?? input.str("pattern") ?? input.str("query")
            ?? (path.isEmpty ? nil : path) ?? input.str("name") ?? input.str("description") ?? input.str("url") ?? ""
        if n.contains("read") || n.contains("grep") || n.contains("glob") || n.contains("list") || n.contains("fetch") {
            return (.read, base.isEmpty ? "读取" : "读取 \(base)", detail)
        }
        if n.contains("edit") || n.contains("write") || n.contains("patch") {
            return (.edit, base.isEmpty ? "编辑" : "编辑 \(base)", detail)
        }
        if n.contains("bash") || n.contains("shell") || n.contains("run") {
            return (.shell, "运行", String((input.str("command") ?? detail).prefix(80)))
        }
        if n == "skill" { return (.info, "技能 " + (input.str("name") ?? ""), "") }
        if n.contains("todo") { return (.info, "规划任务", "") }
        if n.contains("task") { return (.info, "子任务", detail) }
        return (.info, name, detail)
    }
}

// MARK: - Plain text agents (gemini / cursor-agent / aider / fallback)

struct PlainAdapter: AgentAdapter {
    let spec: AgentSpec

    func command(task: String, model: String, workdir: String, autoApprove: Bool) -> [String] {
        switch spec.id {
        case "gemini":
            var a = ["-p", task]
            if !model.isEmpty { a += ["-m", model] }
            if autoApprove { a += ["--yolo"] }
            return a
        case "cursor":
            var a = ["-p", task, "--output-format", "text"]
            if !model.isEmpty { a += ["--model", model] }
            if autoApprove { a += ["--force"] }
            return a
        case "aider":
            var a = ["--message", task, "--no-stream", "--no-pretty"]
            if autoApprove { a += ["--yes-always"] }
            if !model.isEmpty { a += ["--model", model] }
            return a
        default:
            return [task]
        }
    }
}
