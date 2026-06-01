import Foundation

// Auto-judge: a configurable third model compares the two agent outputs and
// returns a structured verdict. The judge can be ANY installed agent (claude /
// codex / opencode / gemini / …) so you can avoid same-vendor bias.
//
// - claude-code: uses --output-format json --json-schema for guaranteed structure.
// - others: run the agent once, asking for JSON only, then extract the object.
enum Judge {

    static let schema = """
    {"type":"object","additionalProperties":false,
     "properties":{
       "winner":{"type":"string"},
       "scores":{"type":"array","items":{"type":"number","minimum":0,"maximum":10}},
       "criteria":{"type":"array","minItems":5,"maxItems":5,"items":{"type":"object","additionalProperties":false,
         "properties":{"name":{"type":"string"},"scores":{"type":"array","items":{"type":"integer","minimum":1,"maximum":10}},"note":{"type":"string"}},
         "required":["name","scores","note"]}},
       "rationale":{"type":"string"}},
     "required":["winner","scores","criteria","rationale"]}
    """

    struct Outcome { var verdict: Verdict?; var error: String? }

    static func run(task: String, runs: [RunResult],
                    judgeAgentId: String, judgeModel: String, judgeBin: String,
                    env: [String: String] = [:]) async -> Outcome {
        let prompt = buildPrompt(task: task, runs: runs)
        let spec = AgentCatalog.spec(judgeAgentId)
        let label = spec.name + (judgeModel.isEmpty ? "" : " · \(judgeModel)")

        let verdictObj: [String: Any]?
        var raw = ""
        if judgeAgentId == "claude-code" || spec.recipe?.parser == "claude" {
            var args = ["-p", prompt, "--output-format", "json", "--json-schema", schema, "--tools", ""]
            if !judgeModel.isEmpty { args += ["--model", judgeModel] }
            if env["ANTHROPIC_AUTH_TOKEN"] != nil || env["ANTHROPIC_API_KEY"] != nil { args += ["--bare"] }
            let captured = await capture(bin: judgeBin, args: args, cwd: nil, env: env)
            raw = captured.out
            guard captured.code == 0 else {
                return Outcome(verdict: nil, error: "裁判调用失败（退出码 \(captured.code)）\n" + String(raw.suffix(300)))
            }
            verdictObj = parseClaude(captured.out)
        } else {
            raw = await captureAgentText(agentId: judgeAgentId, prompt: prompt,
                                         model: judgeModel, bin: judgeBin, env: env)
            verdictObj = extractVerdict(raw)
        }
        guard let v = verdictObj else {
            return Outcome(verdict: nil, error: "无法从裁判输出解析出评分 JSON。裁判最后说：\n" + String(raw.suffix(300)))
        }
        return Outcome(verdict: makeVerdict(v, judgeLabel: label), error: nil)
    }

    // MARK: building the verdict

    private static func makeVerdict(_ v: [String: Any], judgeLabel: String) -> Verdict {
        var scores = (v["scores"] as? [Any] ?? []).map { ($0 as? Double) ?? Double(($0 as? Int) ?? 0) }
        if scores.contains(where: { $0 > 10 }) { scores = scores.map { $0 / 10 } }
        scores = scores.map { min(10, max(0, $0)) }
        var crit = (v["criteria"] as? [[String: Any]] ?? []).map { c in
            Criterion(name: c.str("name") ?? "",
                      scores: (c["scores"] as? [Any] ?? []).map { ($0 as? Int) ?? Int(($0 as? Double) ?? 0) },
                      note: c.str("note") ?? "")
        }
        let maxCrit = crit.flatMap { $0.scores }.max() ?? 0
        if maxCrit > 10 {
            let scale = Double(maxCrit) / 10.0
            crit = crit.map { Criterion(name: $0.name, scores: $0.scores.map { Int((Double($0) / scale).rounded()) }, note: $0.note) }
        }
        return Verdict(judge: judgeLabel, winner: v.str("winner") ?? "tie",
                       scores: scores, criteria: crit, rationale: v.str("rationale") ?? "")
    }

    // MARK: claude structured output

    private static func parseClaude(_ captured: String) -> [String: Any]? {
        guard let top = JSON.parse(captured) ?? extractAnyObject(captured) else { return nil }
        if let so = top["structured_output"] as? [String: Any] { return so }
        if let r = top["result"] as? [String: Any] { return r }
        if let s = top["result"] as? String, let p = JSON.parse(s) { return p }
        if top["winner"] != nil { return top }
        return extractVerdict(captured)
    }

    // MARK: generic agent → text → JSON

    private static func captureAgentText(agentId: String, prompt: String,
                                         model: String, bin: String, env: [String: String]) async -> String {
        let adapter = Adapters.make(agentId)
        // a throwaway scratch dir (some CLIs require a working root)
        let tmp = NSTemporaryDirectory() + "agentbench-judge-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let args = adapter.command(task: prompt, model: model, workdir: tmp, autoApprove: true)

        final class Acc: @unchecked Sendable {
            var acc = RunAccumulator(); let lock = NSLock()
            func snap() -> RunAccumulator { lock.lock(); defer { lock.unlock() }; return acc }
        }
        let box = Acc()
        _ = await ProcessRunner.run(executable: bin, args: args, cwd: tmp, extraEnv: env) { line in
            box.lock.lock(); adapter.parse(line, into: &box.acc); box.lock.unlock()
        }
        try? FileManager.default.removeItem(atPath: tmp)
        let a = box.snap()
        let text = a.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? a.rawLines.joined(separator: "\n") : text
    }

    // MARK: prompt

    private static func buildPrompt(task: String, runs: [RunResult]) -> String {
        func block(_ i: Int, _ run: RunResult) -> String {
            let ans = run.answer
            let files = (ans?.files ?? []).map { "- \($0.path) (+\($0.add)/-\($0.del))\($0.deleted == true ? " [删除]" : "")" }.joined(separator: "\n")
            let code = String((ans?.code ?? "").prefix(5000))
            let m = run.metrics
            return """
            ## Agent \(Lane.label(i))
            延迟: \(m.latencyMs)ms · tokens: \(m.tokensTotal)\(m.tokensEstimated ? "(估算)" : "") · 成本: \(m.costKnown ? String(format: "$%.4f", m.costUsd) : "未知") · 新增行数: \(m.lines)
            说明:
            \(ans?.summary ?? "")
            改动文件:
            \(files.isEmpty ? "(无)" : files)
            代码/Diff:
            ```
            \(code)
            ```
            """
        }
        let n = runs.count
        let labels = (0..<n).map { Lane.label($0) }.joined(separator: "/")
        let blocks = runs.enumerated().map { block($0.offset, $0.element) }.joined(separator: "\n\n")
        return """
        你是严格的资深工程评审。下面是 \(n) 个编码 agent 在同一任务上的产出，请客观评判。不要使用任何工具，直接给出判断。

        # 任务
        \(task)

        \(blocks)

        # 评分要求
        共 \(n) 个 agent，顺序为 \(labels)。
        五个维度（正确性、完整度、代码质量、遵循约束、效率）各为每个 agent 打 1-10 整数分：criteria 共 5 项，每项的 scores 是长度 \(n) 的整数数组（顺序同 \(labels)），并给一句中文 note。
        再给长度 \(n) 的总分数组 scores（0-10，可带一位小数，顺序同上），胜者 winner（取 \(labels) 之一或 tie），以及中文综合理由 rationale。

        只输出一个 JSON 对象，不要代码围栏或多余文字，结构：
        {"winner":"\(Lane.label(0))","scores":[每个agent的数字],"criteria":[{"name":"正确性","scores":[每个agent整数],"note":"..."}, ...共5项],"rationale":"..."}
        """
    }

    // MARK: JSON extraction helpers

    private static func capture(bin: String, args: [String], cwd: String?, env: [String: String] = [:]) async -> (out: String, code: Int32) {
        let collector = TextCollector()
        let code = await ProcessRunner.run(executable: bin, args: args, cwd: cwd, extraEnv: env) { line in
            if !line.isErr { collector.addLine(line.text) }
        }
        return (collector.value, code)
    }

    // Find a balanced {...} that parses and contains "winner".
    static func extractVerdict(_ s: String) -> [String: Any]? {
        let chars = Array(s)
        var starts: [Int] = []
        for (i, ch) in chars.enumerated() {
            if ch == "{" { starts.append(i) }
            else if ch == "}" {
                guard let open = starts.popLast() else { continue }
                let sub = String(chars[open...i])
                if sub.contains("winner"), let o = JSON.parse(sub), o["winner"] != nil { return o }
            }
        }
        return nil
    }

    private static func extractAnyObject(_ s: String) -> [String: Any]? {
        let chars = Array(s); var depth = 0, end = -1
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            if chars[i] == "}" { if depth == 0 { end = i }; depth += 1 }
            else if chars[i] == "{" { depth -= 1; if depth == 0, end >= 0 {
                if let o = JSON.parse(String(chars[i...end])) { return o } } }
        }
        return nil
    }
}
