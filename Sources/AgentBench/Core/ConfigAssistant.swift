import Foundation

// In-app config assistant: describe what you want in plain language and a working
// agent (claude by default) rewrites agents.json for you. You review the proposed
// file, then apply + reload — no hand-editing JSON.
enum ConfigAssistant {

    struct Proposal {
        var note: String              // agent's explanation (Chinese)
        var proposedJSON: String?     // full new agents.json to apply
        var agentCount: Int
        var error: String?
        var env: [String: String] = [:]   // env vars the assistant found/needs (e.g. ARK_API_KEY)
    }

    // Pick a working agent: prefer claude (structured output), else first installed.
    static func defaultAgent(_ avails: [AgentAvailability]) -> (id: String, bin: String)? {
        if let c = avails.first(where: { $0.spec.id == "claude-code" && $0.installed }), let p = c.path { return ("claude-code", p) }
        if let f = avails.first(where: { $0.installed }), let p = f.path { return (f.spec.id, p) }
        return nil
    }

    static let schema = """
    {"type":"object",
     "properties":{
       "_note":{"type":"string"},
       "agents":{"type":"array","items":{"type":"object",
         "required":["id","name","bin","args"],
         "properties":{
           "id":{"type":"string"},"name":{"type":"string"},"vendor":{"type":"string"},
           "glyph":{"type":"string"},"bin":{"type":"string"},
           "models":{"type":"array","items":{"type":"string"}},
           "installHint":{"type":"string"},
           "parser":{"type":"string","enum":["claude","codex","opencode","text"]},
           "args":{"type":"array","items":{"type":"string"}},
           "modelArgs":{"type":"array","items":{"type":"string"}},
           "autoApproveArgs":{"type":"array","items":{"type":"string"}},
           "resumeArgs":{"type":"array","items":{"type":"string"}}}}}},
     "required":["agents"]}
    """

    // Streamed turns of the assistant's own run (reasoning / tool calls / answer).
    static func turns(from acc: RunAccumulator) -> [Turn] {
        var ts = AgentRunner.turns(from: acc)
        let ans = acc.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ans.isEmpty { ts.append(Turn(kind: .answer, summary: ans)) }
        return ts
    }

    // Runs the config agent AGENTICALLY (tools on) so it can actually test candidate
    // CLIs while configuring; streams its turns/tool-use, then extracts the config.
    static func run(request: String, currentJSON: String, agentId: String, bin: String,
                    sandbox: Bool, model: String = "", env: [String: String] = [:],
                    onUpdate: @escaping @Sendable ([Turn]) -> Void) async -> Proposal {
        let prompt = buildPrompt(request: request, currentJSON: currentJSON)
        let adapter = Adapters.make(agentId)
        let tmp = NSTemporaryDirectory() + "agentbench-cfg-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        var args = adapter.command(task: prompt, model: model, workdir: tmp, autoApprove: true)
        args = AgentRunner.bareIfCustomToken(args, agentId: agentId, env: env)
        let (exe, finalArgs) = AgentRunner.sandboxWrap(bin, args, workdir: tmp, agentId: agentId, sandbox: sandbox)

        final class Box: @unchecked Sendable { var acc = RunAccumulator(); let lock = NSLock(); var last = Date.distantPast
            func snap() -> RunAccumulator { lock.lock(); defer { lock.unlock() }; return acc } }
        let box = Box()
        _ = await ProcessRunner.run(executable: exe, args: finalArgs, cwd: tmp, extraEnv: env) { line in
            box.lock.lock()
            adapter.parse(line, into: &box.acc)
            let now = Date(); let should = now.timeIntervalSince(box.last) > 0.08
            if should { box.last = now }
            let snap = should ? turns(from: box.acc) : nil
            box.lock.unlock()
            if let snap { onUpdate(snap) }
        }
        try? FileManager.default.removeItem(atPath: tmp)
        let acc = box.snap()
        onUpdate(turns(from: acc))

        guard let o = extractObject(acc.answerText, mustContain: "agents")
                ?? extractObject(acc.rawLines.joined(separator: "\n"), mustContain: "agents"),
              let agents = o["agents"] as? [[String: Any]] else {
            // surface WHY it failed: show the assistant's final message (often the real cause)
            let final = acc.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = final.isEmpty ? acc.rawLines.suffix(6).joined(separator: "\n") : String(final.suffix(500))
            return Proposal(note: "", proposedJSON: nil, agentCount: 0,
                            error: "助手没有产出配置 JSON。它最后说：\n\(tail)")
        }
        let note = (o["_note"] as? String) ?? ""
        let envOut = (o["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        // validate it decodes as our config
        let clean: [String: Any] = ["_说明": note.isEmpty ? "由配置助手生成" : note, "agents": agents]
        guard let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys]),
              (try? JSONDecoder().decode(UserAgentsFile.self, from: data)) != nil,
              let pretty = String(data: data, encoding: .utf8) else {
            return Proposal(note: note, proposedJSON: nil, agentCount: 0, error: "助手产出的配置结构不合法")
        }
        return Proposal(note: note, proposedJSON: pretty, agentCount: agents.count, error: nil, env: envOut)
    }

    // Verify a proposed config actually works: for each agent, find its CLI and
    // run a tiny task to confirm it launches and produces output.
    struct VerifyResult: Identifiable { var id: String; var name: String; var ok: Bool; var detail: String }

    static func verify(_ json: String, env: [String: String] = [:], timeoutSec: UInt64 = 75) async -> [VerifyResult] {
        let agents = AgentConfigFile.parse(json)
        var out: [VerifyResult] = []
        for u in agents {
            let spec = AgentConfigFile.spec(from: u)
            guard let bin = ProcessRunner.which(spec.bin) else {
                out.append(VerifyResult(id: u.id, name: u.name, ok: false, detail: "未找到 CLI：\(spec.bin)（不在 PATH）")); continue
            }
            let adapter = ConfigAdapter(spec: spec, recipe: spec.recipe!)
            let tmp = NSTemporaryDirectory() + "agentbench-verify-" + UUID().uuidString.prefix(8)
            try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let model = spec.models.first ?? ""
            var args = adapter.command(task: "只回复一个词：OK。不要做其它任何事。", model: model, workdir: tmp, autoApprove: true)
            args = AgentRunner.bareIfCustomToken(args, agentId: spec.id, env: env)   // match real runs

            let collector = TextCollector()
            let runTask = Task { await ProcessRunner.run(executable: bin, args: args, cwd: tmp, extraEnv: env) {
                if !$0.text.isEmpty { collector.addLine(($0.isErr ? "! " : "") + $0.text) } } }
            let timeoutTask = Task { try? await Task.sleep(nanoseconds: timeoutSec * 1_000_000_000); runTask.cancel() }
            let code = await runTask.value
            timeoutTask.cancel()
            try? FileManager.default.removeItem(atPath: tmp)

            let log = collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(log.suffix(180)).replacingOccurrences(of: "\n", with: " ")
            // strict: success requires exit 0 AND no usage/error signature in output
            let lc = log.lowercased()
            let failMarkers = ["unknown option", "unrecognized", "usage:", "error:", "invalid ",
                               "no such", "not found", "command not found", "未知", "tip: to pass",
                               "missing", "required argument", "panic", "traceback"]
            let looksError = failMarkers.contains { lc.contains($0) }
            if code == 0 && !looksError {
                out.append(VerifyResult(id: u.id, name: u.name, ok: true, detail: "可运行 · \(tail.isEmpty ? "退出 0" : tail)"))
            } else if code != 0 && log.isEmpty {
                out.append(VerifyResult(id: u.id, name: u.name, ok: false, detail: "退出码 \(code)，无输出（可能超时/未登录/命令模板有误）"))
            } else {
                let why = looksError ? "命令报错（参数/用法不对）" : "退出码 \(code)"
                out.append(VerifyResult(id: u.id, name: u.name, ok: false, detail: "\(why) · \(tail)"))
            }
        }
        return out
    }

    // Write the proposal to agents.json (backing up the old one).
    static func apply(_ json: String) throws {
        let url = AgentConfigFile.url
        if let old = try? Data(contentsOf: url) {
            try? old.write(to: url.deletingPathExtension().appendingPathExtension("bak.json"))
        }
        try json.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: prompt

    private static func buildPrompt(request: String, currentJSON: String) -> String {
        let builtins = AgentCatalog.builtin.map { "\($0.id)(\($0.name), bin=\($0.bin))" }.joined(separator: ", ")
        return """
        你是 AgentBench 的配置助手。AgentBench 通过 agents.json 让用户声明可调用的编码 agent CLI。不要使用任何工具，直接思考并输出 JSON。

        # agents.json 格式
        顶层 {"agents":[ ... ]}。每个 agent 字段：
        - id(唯一)、name、vendor、glyph(单个字符/emoji)、bin(PATH 上的可执行名)
        - models(建议模型数组，可空)、installHint(安装提示)
        - parser: 用哪个内置解析器 —— "claude"(stream-json)/"codex"(exec --json)/"opencode"/"text"(通用纯文本，新 CLI 先用这个)
        - args: 启动命令模板(数组)。占位符: {task} {model} {workdir}
        - modelArgs: 仅当选了模型时追加(如 ["--model","{model}"])
        - autoApproveArgs: 自动批准时追加(如 ["--yes"])
        - resumeArgs: 多轮续接命令(占位符 {message} {sessionId} {workdir})，没有就省略

        内置 agent(无需在 agents.json 重复，除非要覆盖): \(builtins)

        # 当前 agents.json
        ```json
        \(currentJSON)
        ```

        # 用户需求
        \(request)

        # 工作方式（重要）
        你可以使用工具（如 Bash）来**实际验证**配置是否可行，例如：
        - `command -v <bin>` / `which <bin>` 确认 CLI 是否安装；
        - `<bin> --help` 查看它真实支持的参数，避免编造不存在的选项（比如 claude 没有 `--cwd`）；
        - 用一个最小 prompt 真跑一次该命令模板，确认能跑通。
        请边测边定，确保 args / resumeArgs 里的参数都是该 CLI 真实存在的。

        # claude 接第三方中转（重要经验）
        给 claude（parser="claude"）配自定义中转 agent（如火山 ark、各家 Anthropic 兼容网关）时：
        - 注入 `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`（放进顶层 env 或让用户已配在运行环境变量里）。
        - **args 里必须带 `--bare`**！否则 claude 会优先用本机 OAuth 登录态、忽略注入的 token，去打中转 → 鉴权失败。例：`["-p","{task}","--output-format","stream-json","--verbose","--dangerously-skip-permissions","--bare"]`。
        - 注意：claude 只能连 **Anthropic 兼容**端点。若中转只有 OpenAI 接口（如火山 ark 的 /api/v3 只支持 chat/completions），claude 仍连不上（无 /v1/messages）。这种情况建议改用 opencode（其 doubao provider 已 OpenAI 兼容）。

        # codex 接第三方中转（重要经验）
        给 codex 配自定义 OpenAI 兼容 provider（火山 ark / doubao / 各家中转）时：
        - **`wire_api` 用 `"chat"`，不要用 `"responses"`**——Responses API 下 codex 会发它自带的工具定义，第三方中转常不认（典型报错：`unknown tool type: ...` / BadRequest param=tool.type）。chat/completions 兼容性最好。
        - base_url 用中转给的（如 `https://ark.cn-beijing.volces.com/api/v3`）；env_key 指向运行环境里的 key 名。
        - model 用中转支持的模型名或**接入点 ID（ep-...）**——拿不准就在 cc-switch 配置里看现成可用的那个。
        - 可用 `codex exec --json -c model_provider=... -c 'model_providers.X.base_url=...' -c 'model_providers.X.wire_api="chat"' -c 'model_providers.X.env_key="..."' -m <model> "测试"` 实跑验证。

        # 环境变量（重要）
        有些 agent/provider 需要环境变量里的 API key（例如 codex 自定义 provider 的 env_key 引用 ARK_API_KEY / OPENAI_API_KEY）。
        你可以**主动去本机已有配置里找到对应的 key 值**并替用户填好，例如：
        - cc-switch: `sqlite3 ~/.cc-switch/cc-switch.db "SELECT settings_config FROM providers"`（codex provider 的 key 常在 settings_config.auth 里）；
        - `~/.codex/`、`~/.config/`、环境变量等。
        把这些键值放进最终 JSON 的顶层 `env` 对象。它们会被注入到 agent 运行环境（仅保存在本机）。

        # 最终输出（必须遵守）
        无论测试成功还是失败，你的**最后一条消息都必须只包含一个 JSON 对象**（不要代码围栏、不要多余文字）：
        {"_note":"<中文说明你做了什么、测了什么、填了哪些 env>","agents":[ ...完整数组... ],"env":{"ARK_API_KEY":"...可选..."}}
        - `env` 可省略或为空对象；有需要的 key 就填上真实值。
        - 即使某个 provider 测试 401/连不上，也照样把配置写进 agents，把失败原因写进 _note。
        - 若用户只是提问、无需改配置，则 agents 原样返回，在 _note 里中文回答。
        - 这是机器解析的接口：最后一条消息除了这个 JSON 不要有任何其它内容。
        """
    }

    // MARK: helpers (mirror Judge's robust extraction)

    private static func capture(bin: String, args: [String]) async -> (out: String, code: Int32) {
        let c = TextCollector()
        let code = await ProcessRunner.run(executable: bin, args: args, cwd: nil) { if !$0.isErr { c.addLine($0.text) } }
        return (c.value, code)
    }

    private static func captureAgentText(agentId: String, prompt: String, bin: String) async -> String {
        let adapter = Adapters.make(agentId)
        let tmp = NSTemporaryDirectory() + "agentbench-cfg-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let args = adapter.command(task: prompt, model: "", workdir: tmp, autoApprove: true)
        final class Acc: @unchecked Sendable { var a = RunAccumulator(); let l = NSLock()
            func snap() -> RunAccumulator { l.lock(); defer { l.unlock() }; return a } }
        let box = Acc()
        _ = await ProcessRunner.run(executable: bin, args: args, cwd: tmp) { line in
            box.l.lock(); adapter.parse(line, into: &box.a); box.l.unlock()
        }
        try? FileManager.default.removeItem(atPath: tmp)
        let a = box.snap()
        let t = a.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? a.rawLines.joined(separator: "\n") : t
    }

    private static func parseClaude(_ s: String) -> [String: Any]? {
        guard let top = JSON.parse(s) ?? extractObject(s, mustContain: "agents") else { return nil }
        if let so = top["structured_output"] as? [String: Any] { return so }
        if let r = top["result"] as? [String: Any] { return r }
        if let str = top["result"] as? String, let p = JSON.parse(str) { return p }
        if top["agents"] != nil { return top }
        return extractObject(s, mustContain: "agents")
    }

    private static func extractObject(_ s: String, mustContain: String) -> [String: Any]? {
        let chars = Array(s); var starts: [Int] = []
        for (i, ch) in chars.enumerated() {
            if ch == "{" { starts.append(i) }
            else if ch == "}" {
                guard let open = starts.popLast() else { continue }
                let sub = String(chars[open...i])
                if sub.contains(mustContain), let o = JSON.parse(sub), o[mustContain] != nil { return o }
            }
        }
        return nil
    }
}
