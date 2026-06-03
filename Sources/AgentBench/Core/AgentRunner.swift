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
        args = codexProviderArgs(args, agentId: config.agentId, env: env)
        let (exe, finalArgs) = sandboxWrap(binPath, args, workdir: prepared.dir,
                                           agentId: config.agentId, sandbox: sandbox)

        let box = Box()
        let started = Date()

        // 2. stream
        let exit = await ProcessRunner.run(
            executable: exe, args: finalArgs, cwd: prepared.dir, extraEnv: env,
            dropEnvKeys: anthropicCleanKeys(agentId: config.agentId, env: env)
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
            codeLines: changes.codeLines,
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
        args = codexProviderArgs(args, agentId: config.agentId, env: env)
        let (exe, finalArgs) = sandboxWrap(binPath, args, workdir: workdir,
                                           agentId: config.agentId, sandbox: sandbox)
        let baseTurns = prior.turns
        let liveBase = result        // immutable snapshot for the streaming callback
        let box = Box()
        let started = Date()

        _ = await ProcessRunner.run(executable: exe, args: finalArgs, cwd: workdir, extraEnv: env,
                                    dropEnvKeys: anthropicCleanKeys(agentId: config.agentId, env: env)) { line in
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
                             code: changes.primaryCode, codeLines: changes.codeLines,
                             previewHTML: changes.previewHTML,
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
        // prior.rawLog may be only a tail marker (the full log was externalized to a
        // sidecar). Read the full log back before appending so a follow-up doesn't
        // drop the earlier rounds; clear rawLogPath so the grown log re-externalizes.
        let priorFull = Store.fullRawLog(prior)
        result.rawLog = priorFull + "\n--- 续接 ---\n" + acc.rawLines.joined(separator: "\n")
        result.rawLogPath = nil
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
        if agentId == "codex" || AgentCatalog.spec(agentId).recipe?.parser == "codex" {
            let want = sandbox ? "--full-auto" : "--dangerously-bypass-approvals-and-sandbox"
            let drop = sandbox ? "--dangerously-bypass-approvals-and-sandbox" : "--full-auto"
            var a = args.filter { $0 != drop }
            if !a.contains(want) { a.append(want) }
            // codex's workspace-write sandbox is narrower than our seatbelt profile: it
            // denies network and only treats the workspace as writable. Open it up to
            // match — network on, plus the same safe write roots (caches/user config) so
            // pip --user / npm / build caches work — while writes still can't escape to
            // the user's real project.
            if sandbox {
                if !a.contains(where: { $0.contains("network_access") }) {
                    a += ["-c", "sandbox_workspace_write.network_access=true"]
                }
                if !a.contains(where: { $0.contains("writable_roots") }) {
                    let h = NSHomeDirectory()
                    let roots = ["/tmp", "\(h)/.cache", "\(h)/.npm", "\(h)/.local", "\(h)/.cargo",
                                 "\(h)/.codex", "\(h)/.config", "\(h)/.cursor", "\(h)/.aider",
                                 "\(h)/Library/Caches"]
                    let toml = "[" + roots.map { "\"\($0)\"" }.joined(separator: ",") + "]"
                    a += ["-c", "sandbox_workspace_write.writable_roots=\(toml)"]
                }
            }
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
    // codex reads its provider/endpoint from ~/.codex/config.toml, NOT from arbitrary
    // env vars — so an injected OPENAI_BASE_URL alone is ignored and codex hits the
    // default endpoint (why "configure codex via agents.json env" failed while
    // cc-switch, which writes config.toml, worked). Translate the relay env into
    // inline `-c` overrides so a base_url + key fully drive codex with no config file.
    // wire_api=chat (not responses) — third-party relays usually reject codex's
    // Responses-API tool definitions.
    static func codexProviderArgs(_ args: [String], agentId: String, env: [String: String]) -> [String] {
        let isCodex = agentId == "codex" || AgentCatalog.spec(agentId).recipe?.parser == "codex"
        guard isCodex else { return args }
        // a custom template already wiring a provider → don't double-configure
        if args.contains(where: { $0.contains("model_provider") }) { return args }
        // base_url / key may arrive via the per-run recipe env OR global customEnv —
        // both get injected into the process, so consult the merged view (run wins).
        let custom = (UserDefaults.standard.dictionary(forKey: "customEnv") as? [String: String]) ?? [:]
        let merged = custom.merging(env) { _, run in run }
        guard let base = (merged["OPENAI_BASE_URL"] ?? merged["CODEX_BASE_URL"]), !base.isEmpty else { return args }
        let keyName = merged["OPENAI_API_KEY"] != nil ? "OPENAI_API_KEY"
            : (merged.keys.first { $0.uppercased().hasSuffix("_API_KEY") }
               ?? merged.keys.first { $0.uppercased().hasSuffix("KEY") }
               ?? "OPENAI_API_KEY")
        // Modern codex only speaks the Responses API, but most relays are
        // chat/completions-only. Route through the in-app Responses→chat proxy when
        // it's up: codex talks Responses to the loopback proxy, which translates to
        // the upstream chat endpoint (key flows through codex's Bearer header).
        // Fall back to a direct provider if the proxy isn't ready.
        let useBase: String, wire: String
        if let proxied = CodexRelayProxy.shared.baseURL(forUpstream: base) {
            useBase = proxied; wire = "responses"
        } else {
            useBase = base
            wire = merged["CODEX_WIRE_API"].map { $0.lowercased() == "responses" ? "responses" : "chat" } ?? "chat"
        }
        let p = "agentbench"
        return args + [
            "-c", "model_provider=\"\(p)\"",
            "-c", "model_providers.\(p).name=\"AgentBench Relay\"",
            "-c", "model_providers.\(p).base_url=\"\(useBase)\"",
            "-c", "model_providers.\(p).wire_api=\"\(wire)\"",
            "-c", "model_providers.\(p).env_key=\"\(keyName)\"",
        ]
    }

    // The built-in claude-code is meant to be the user's CLEAN real-Anthropic login.
    // cc-switch (and relay setups) export ANTHROPIC_* globally in the login shell,
    // which baseEnv() inherits — silently redirecting built-in claude or remapping its
    // sonnet/opus/haiku aliases to a relay-only model (e.g. mimo) → 404. Strip those for
    // built-in claude only; a relay agent injects ANTHROPIC_BASE_URL itself (intentional).
    static let anthropicRelayKeys = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME", "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME", "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
    ]
    static func anthropicCleanKeys(agentId: String, env: [String: String]) -> [String] {
        guard agentId == "claude-code", env["ANTHROPIC_BASE_URL"] == nil else { return [] }
        return anthropicRelayKeys
    }

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
