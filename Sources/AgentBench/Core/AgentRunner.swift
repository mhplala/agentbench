import Foundation

// Runs ONE agent for one side: prepares an isolated workspace, launches the CLI,
// streams parsed turns live, then collects the real diff + metrics.
enum AgentRunner {

    // Thread-safe accumulator box shared with the (background) line callback.
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var acc = RunAccumulator()
        var lastEmit = Date.distantPast
        // non-async accessor so callers in async contexts don't touch NSLock directly
        func snapshot() -> RunAccumulator { lock.lock(); defer { lock.unlock() }; return acc }
    }

    static func run(
        config: AgentConfig,
        task: String,
        sessionId: String,
        lane: Int,
        autoApprove: Bool,
        binPath: String,
        env: [String: String] = [:],
        sandbox: Bool = true,
        onUpdate: @escaping @Sendable (RunResult) -> Void
    ) async -> RunResult {

        var result = RunResult()
        result.status = .running

        // 1. isolated workspace
        let prepared: (dir: String, isGit: Bool)
        do {
            prepared = try Workspace.prepare(repo: config.repo, sessionId: sessionId, lane: lane)
        } catch {
            result.status = .failed
            result.error = error.localizedDescription
            return result
        }
        result.workdir = prepared.dir
        let before = prepared.isGit ? [:] : Workspace.snapshot(prepared.dir)

        let adapter = Adapters.make(config.agentId)
        var args = adapter.command(task: task, model: config.model,
                                   workdir: prepared.dir, autoApprove: autoApprove)
        args = bareIfCustomToken(args, agentId: config.agentId, env: env)
        let (exe, finalArgs) = sandboxWrap(binPath, args, workdir: prepared.dir,
                                           agentId: config.agentId, sandbox: sandbox)

        let box = Box()
        let started = Date()

        // 2. stream
        let exit = await ProcessRunner.run(
            executable: exe, args: finalArgs, cwd: prepared.dir, extraEnv: env
        ) { line in
            box.lock.lock()
            adapter.parse(line, into: &box.acc)
            let now = Date()
            let should = now.timeIntervalSince(box.lastEmit) > 0.07
            if should { box.lastEmit = now }
            let snapshotTurns = should ? turns(from: box.acc) : nil
            box.lock.unlock()
            if let snapshotTurns {
                var live = RunResult()
                live.status = .running
                live.turns = snapshotTurns
                live.workdir = prepared.dir
                onUpdate(live)
            }
        }

        // 3. finalize (process exited → no more callbacks; snapshot under lock)
        let acc = box.snapshot()

        let changes = Workspace.collectChanges(dir: prepared.dir, isGit: prepared.isGit, before: before)

        var metrics = Metrics()
        metrics.latencyMs = acc.durationMs ?? Int(Date().timeIntervalSince(started) * 1000)
        metrics.toolCalls = acc.tools.count
        metrics.turns = max(acc.turns, acc.tools.count)
        metrics.lines = changes.linesAdded

        let answerTrimmed = acc.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if acc.sawStructuredTokens {
            metrics.tokensIn = acc.tokensIn
            metrics.tokensOut = acc.tokensOut
            metrics.tokensEstimated = false
        } else {
            metrics.tokensIn = estimateTokens(task)
            metrics.tokensOut = estimateTokens(answerTrimmed + "\n" + changes.unifiedDiff)
            metrics.tokensEstimated = true
        }
        if let c = acc.cost {
            metrics.costUsd = c; metrics.costKnown = true
        } else {
            metrics.costKnown = false
        }

        var turnsOut = turns(from: acc)
        let summary = answerTrimmed.isEmpty
            ? (changes.files.isEmpty ? "（agent 未产生可见输出）" : "完成，改动见下方文件与代码。")
            : answerTrimmed
        let answer = Turn(
            kind: .answer,
            summary: summary,
            files: changes.files,
            code: changes.primaryCode,
            previewHTML: changes.previewHTML,
            previewPath: changes.previewPath
        )
        turnsOut.append(answer)

        result.turns = turnsOut
        result.metrics = metrics
        result.rawLog = acc.rawLines.joined(separator: "\n")
        result.workdir = prepared.dir
        result.sessionId = acc.sessionId

        let producedSomething = !changes.files.isEmpty || !answerTrimmed.isEmpty
        if let em = acc.errorMessage, !producedSomething {
            result.status = .failed
            result.error = em
        } else if exit == 0 || producedSomething {
            // some agents exit non-zero but still produced changes/output
            result.status = .done
        } else {
            result.status = .failed
            let errTail = acc.rawLines.suffix(8).joined(separator: "\n")
            result.error = (acc.errorMessage.map { $0 + "\n" } ?? "")
                + "退出码 \(exit)" + (errTail.isEmpty ? "" : "\n" + errTail)
        }
        return result
    }

    // Continue an existing run with a follow-up message (multi-turn). The agent
    // resumes its session in the SAME workdir; `prior` already has the user turn
    // appended so live updates show it immediately. Metrics accumulate across rounds.
    static func continueRun(
        prior: RunResult,
        config: AgentConfig,
        message: String,
        autoApprove: Bool,
        binPath: String,
        env: [String: String] = [:],
        sandbox: Bool = true,
        onUpdate: @escaping @Sendable (RunResult) -> Void
    ) async -> RunResult {
        var result = prior
        result.status = .running
        let workdir = prior.workdir
        guard !workdir.isEmpty, FileManager.default.fileExists(atPath: workdir) else {
            result.status = .failed; result.error = "工作副本已不存在，无法续接"
            return result
        }
        let isGit = Workspace.isGitRepo(workdir)
        if isGit { Workspace.gitBaseline(workdir) }            // baseline → diff this round only
        let before = isGit ? [:] : Workspace.snapshot(workdir)

        let adapter = Adapters.make(config.agentId)
        var args = adapter.resumeArgs(message: message, model: config.model,
                                      workdir: workdir, sessionId: prior.sessionId, autoApprove: autoApprove)
        args = bareIfCustomToken(args, agentId: config.agentId, env: env)
        let (exe, finalArgs) = sandboxWrap(binPath, args, workdir: workdir,
                                           agentId: config.agentId, sandbox: sandbox)
        let baseTurns = prior.turns
        let liveBase = result        // immutable snapshot for the streaming callback
        let box = Box()
        let started = Date()

        _ = await ProcessRunner.run(executable: exe, args: finalArgs, cwd: workdir, extraEnv: env) { line in
            box.lock.lock()
            adapter.parse(line, into: &box.acc)
            let now = Date()
            let should = now.timeIntervalSince(box.lastEmit) > 0.07
            if should { box.lastEmit = now }
            let snap = should ? turns(from: box.acc) : nil
            box.lock.unlock()
            if let snap {
                var live = liveBase
                live.turns = baseTurns + snap
                onUpdate(live)
            }
        }

        let acc = box.snapshot()
        let changes = Workspace.collectChanges(dir: workdir, isGit: isGit, before: before)
        let answerTrimmed = acc.answerText.trimmingCharacters(in: .whitespacesAndNewlines)

        var newTurns = turns(from: acc)
        let summary = answerTrimmed.isEmpty
            ? (changes.files.isEmpty ? "（本轮无可见输出）" : "已根据后续指令更新。")
            : answerTrimmed
        newTurns.append(Turn(kind: .answer, summary: summary, files: changes.files,
                             code: changes.primaryCode, previewHTML: changes.previewHTML,
                             previewPath: changes.previewPath))

        // accumulate metrics across rounds
        var m = prior.metrics
        m.latencyMs += acc.durationMs ?? Int(Date().timeIntervalSince(started) * 1000)
        m.toolCalls += acc.tools.count
        m.turns += max(acc.turns, acc.tools.count)
        m.lines += changes.linesAdded
        if acc.sawStructuredTokens {
            m.tokensIn += acc.tokensIn; m.tokensOut += acc.tokensOut
        } else {
            m.tokensIn += estimateTokens(message)
            m.tokensOut += estimateTokens(answerTrimmed + "\n" + changes.unifiedDiff)
            m.tokensEstimated = true
        }
        if let c = acc.cost { m.costUsd += c } else if !acc.sawStructuredTokens { m.costKnown = false }

        result.turns = baseTurns + newTurns
        result.metrics = m
        result.rawLog += "\n--- 续接 ---\n" + acc.rawLines.joined(separator: "\n")
        result.sessionId = acc.sessionId ?? prior.sessionId
        if let em = acc.errorMessage, answerTrimmed.isEmpty, changes.files.isEmpty {
            result.status = .failed; result.error = em
        } else {
            result.status = .done
        }
        return result
    }

    // Confine an agent run. codex uses its native workspace-write sandbox
    // (--full-auto); everything else is wrapped in seatbelt via sandbox-exec so
    // writes are limited to the workspace + temp + CLI caches.
    static func sandboxWrap(_ exe: String, _ args: [String], workdir: String,
                            agentId: String, sandbox: Bool) -> (String, [String]) {
        // codex exec is non-interactive (it always auto-applies — there is no channel
        // to approve mid-run), so the only meaningful axis is sandboxing. Make the
        // flag follow the sandbox setting deterministically, not autoApprove:
        //   sandbox on  → --full-auto                                (workspace-write sandbox)
        //   sandbox off → --dangerously-bypass-approvals-and-sandbox (no sandbox)
        if agentId == "codex" {
            let want = sandbox ? "--full-auto" : "--dangerously-bypass-approvals-and-sandbox"
            let drop = sandbox ? "--dangerously-bypass-approvals-and-sandbox" : "--full-auto"
            var a = args.filter { $0 != drop }
            if !a.contains(want) { a.append(want) }
            return (exe, a)
        }
        guard sandbox else { return (exe, args) }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return (exe, args) }
        let profile = SandboxProfile.make(workdir: workdir)
        return ("/usr/bin/sandbox-exec", ["-p", profile, exe] + args)
    }

    // Claude Code prefers its OAuth login over ANTHROPIC_AUTH_TOKEN/API_KEY, so an
    // injected provider token is ignored (it sends the OAuth token → 401 on relays
    // like ark/doubao). `--bare` forces strict env-key auth so the provider token
    // is actually used. Only applied when a custom token is injected.
    static func bareIfCustomToken(_ args: [String], agentId: String, env: [String: String]) -> [String] {
        // claude-family = built-in claude OR a custom agent using the "claude" parser
        let isClaude = agentId == "claude-code" || AgentCatalog.spec(agentId).recipe?.parser == "claude"
        guard isClaude, !args.contains("--bare") else { return args }
        // a token may arrive via the per-run env OR the global custom env vars
        let custom = (UserDefaults.standard.dictionary(forKey: "customEnv") as? [String: String]) ?? [:]
        let hasToken = [env, custom].contains { $0["ANTHROPIC_AUTH_TOKEN"] != nil || $0["ANTHROPIC_API_KEY"] != nil }
        guard hasToken else { return args }
        return args + ["--bare"]
    }

    static func turns(from acc: RunAccumulator) -> [Turn] {
        var ts: [Turn] = []
        if !acc.reasoning.isEmpty {
            ts.append(Turn(kind: .think, plan: Array(acc.reasoning.prefix(50))))
        }
        for tool in acc.tools {
            ts.append(Turn(kind: .tool, tool: tool))
        }
        return ts
    }

    static func estimateTokens(_ s: String) -> Int { max(1, s.count / 4) }
}
