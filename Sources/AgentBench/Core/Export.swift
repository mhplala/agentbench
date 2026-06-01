import Foundation
import AppKit

// Exports a full comparison session to a folder the user picks: raw agent logs,
// per-lane readable transcripts, the structured session JSON, the verdict, and a
// summary report — everything needed to keep analyzing a run outside the app.
enum Exporter {

    @MainActor
    static func exportWithPanel(_ session: Session) {
        let panel = NSSavePanel()
        panel.title = "导出 trace 与 log"
        panel.message = "选择导出位置；将创建一个包含日志、转录、指标与裁判结果的文件夹"
        panel.prompt = "导出"
        panel.nameFieldStringValue = suggestedName(session)
        panel.canCreateDirectories = true
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try write(session, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let a = NSAlert()
                a.messageText = "导出失败"
                a.informativeText = error.localizedDescription
                a.alertStyle = .warning
                a.runModal()
            }
        }
    }

    static func suggestedName(_ s: Session) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        let stamp = f.string(from: s.createdAt)
        let agents = s.configs.map { AgentCatalog.spec($0.agentId).id }.joined(separator: "-vs-")
        return "agentbench-\(agents)-\(stamp)"
    }

    // MARK: - write the export bundle

    static func write(_ s: Session, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // structured session (everything, machine-readable)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(s).write(to: dir.appendingPathComponent("session.json"), options: .atomic)

        // verdict (machine-readable), if any
        if let v = s.verdict {
            try enc.encode(v).write(to: dir.appendingPathComponent("verdict.json"), options: .atomic)
        }

        // per-lane raw log + readable transcript
        for i in s.runs.indices {
            let run = s.runs[i]
            let cfg = s.configs.indices.contains(i) ? s.configs[i] : .empty
            let base = "\(Lane.label(i))-\(AgentCatalog.spec(cfg.agentId).id)"
            // prefer the full externalized sidecar log; fall back to the inline tail
            let dst = dir.appendingPathComponent("\(base).log")
            if let rel = run.rawLogPath,
               case let src = Store.dir.appendingPathComponent(rel),
               fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            } else if !run.rawLog.isEmpty {
                try run.rawLog.write(to: dst, atomically: true, encoding: .utf8)
            }
            try transcriptMarkdown(run: run, cfg: cfg, lane: i, task: s.task)
                .write(to: dir.appendingPathComponent("\(base)-transcript.md"),
                       atomically: true, encoding: .utf8)
        }

        // human-readable summary report
        try report(s).write(to: dir.appendingPathComponent("report.md"),
                            atomically: true, encoding: .utf8)
    }

    // MARK: - renderers

    private static func transcriptMarkdown(run: RunResult, cfg: AgentConfig, lane: Int, task: String) -> String {
        var out = "# \(Lane.label(lane)) · \(AgentCatalog.spec(cfg.agentId).name)"
        if !cfg.model.isEmpty { out += " (`\(cfg.model)`)" }
        out += "\n\n**任务**：\(task)\n\n"
        out += "**状态**：\(statusText(run.status)) · 延迟 \(Fmt.sec(run.metrics.latencyMs)) · "
        out += "Tokens \(run.metrics.tokensTotal) · 行数 \(run.metrics.lines)\n\n---\n\n"
        if let err = run.error { out += "> ⚠️ 错误：\(err)\n\n" }

        for turn in run.turns {
            switch turn.kind {
            case .user:
                out += "### 👤 你\n\n\(turn.summary)\n\n"
            case .think:
                out += "### 🧠 推理\n\n"
                for p in turn.plan { out += "- \(p)\n" }
                out += "\n"
            case .tool:
                if let t = turn.tool {
                    let d = t.detail.isEmpty ? "" : " — `\(t.detail)`"
                    out += "- 🔧 **\(t.kind.rawValue)** \(t.label)\(d)\n"
                }
            case .answer:
                out += "\n### 🤖 回答\n\n\(turn.summary)\n\n"
                if !turn.files.isEmpty {
                    out += "**变更文件：**\n\n"
                    for f in turn.files {
                        if f.deleted == true { out += "- ~~\(f.path)~~ (已删除)\n" }
                        else { out += "- \(f.path) (+\(f.add) −\(f.del))\n" }
                    }
                    out += "\n"
                }
                if !turn.code.isEmpty {
                    out += "```\n\(turn.code)\n```\n\n"
                }
            }
        }
        return out
    }

    private static func report(_ s: Session) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = "# AgentBench 对比报告\n\n"
        out += "**任务**：\(s.task)\n\n"
        out += "**创建**：\(f.string(from: s.createdAt))"
        if let fin = s.finishedAt { out += " · **完成**：\(f.string(from: fin))" }
        out += "\n\n## 指标\n\n"
        out += "| Lane | Agent | 模型 | 状态 | 延迟 | Tokens | 成本 | 行数 | 轮次 | 工具调用 |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|\n"
        for i in s.configs.indices {
            let c = s.configs[i]
            let m = s.runs.indices.contains(i) ? s.runs[i].metrics : Metrics()
            let st = s.runs.indices.contains(i) ? statusText(s.runs[i].status) : "—"
            let cost = m.costKnown ? Fmt.usd(m.costUsd) : "—"
            let tok = (m.tokensEstimated ? "≈" : "") + "\(m.tokensTotal)"
            out += "| \(Lane.label(i)) | \(AgentCatalog.spec(c.agentId).name) | \(c.model.isEmpty ? "默认" : c.model) | \(st) | \(Fmt.sec(m.latencyMs)) | \(tok) | \(cost) | \(m.lines) | \(m.turns) | \(m.toolCalls) |\n"
        }
        if let v = s.verdict {
            out += "\n## 裁判（\(v.judge)）\n\n"
            out += "**优胜**：\(v.winner == "tie" ? "平局" : "Agent \(v.winner)")\n\n"
            out += "**总分**：" + v.scores.indices.map { "\(Lane.label($0)) \(String(format: "%.1f", v.scores[$0]))" }.joined(separator: " · ") + "\n\n"
            if !v.criteria.isEmpty {
                out += "| 维度 | " + s.configs.indices.map { Lane.label($0) }.joined(separator: " | ") + " | 说明 |\n"
                out += "|---" + String(repeating: "|---", count: s.configs.count) + "|---|\n"
                for c in v.criteria {
                    let cells = s.configs.indices.map { c.scores.indices.contains($0) ? "\(c.scores[$0])" : "—" }.joined(separator: " | ")
                    out += "| \(c.name) | \(cells) | \(c.note) |\n"
                }
            }
            out += "\n**理由**：\(v.rationale)\n"
        }
        if let vote = s.vote {
            out += "\n## 人工投票\n\n\(vote == "tie" ? "平局" : "Agent \(vote)")\n"
        }
        out += "\n---\n\n> 完整对话见各 lane 的 `*-transcript.md`；原始 CLI 输出见 `*.log`；结构化数据见 `session.json`。\n"
        return out
    }

    private static func statusText(_ s: RunStatus) -> String {
        switch s {
        case .done: return "完成"
        case .failed: return "失败"
        case .running: return "中断"
        case .pending: return "未运行"
        }
    }
}
