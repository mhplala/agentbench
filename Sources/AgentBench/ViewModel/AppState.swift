import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    enum Phase { case compose, running, done }

    @Published var availabilities: [AgentAvailability] = []
    @Published var scanned = false

    @Published var allSessions: [Session] = []
    @Published var live: Session
    @Published var activeId: String = "live"

    // result-view controls
    @Published var artifactView: String = "preview"  // preview | code
    @Published var diff: Bool = false
    @Published var judgeOpen = false
    @Published var compareOpen = false
    @Published var judging = false
    @Published var trustedPreviews: Set<Int> = []    // lanes opted into JS/assets/network
    @Published var followupText = ""

    let prefs = Prefs.shared
    private var runTask: Task<Void, Never>? = nil
    // Manual judge re-run lives in its own handle so a new comparison / cancel can
    // stop it — otherwise a stale retry keeps judging (and burning tokens) in the bg.
    private var judgeTask: Task<Void, Never>? = nil

    init() {
        AgentConfigFile.writeTemplateIfMissing()
        AgentCatalog.reload()
        let loaded = Store.loadSessions()
        var restored = Session()
        if let liveId = UserDefaults.standard.string(forKey: "liveSessionId"),
           var s = loaded.first(where: { $0.id == liveId }) {
            for i in s.runs.indices where s.runs[i].status == .running {
                s.runs[i].status = .failed; s.runs[i].error = "已中断（应用退出）"
            }
            restored = s
        }
        allSessions = loaded
        live = restored
        PreviewServer.shared.start(root: Workspace.runsRoot)
    }

    // MARK: trust / browser (per lane)

    func isTrusted(_ lane: Int) -> Bool { prefs.trustLocalPreviews || trustedPreviews.contains(lane) }
    func trust(_ lane: Int) { trustedPreviews.insert(lane) }
    func openInBrowser(_ lane: Int) {
        guard live.runs.indices.contains(lane), let f = live.runs[lane].previewFileURL else { return }
        NSWorkspace.shared.open(PreviewServer.shared.url(forFile: f) ?? f)
    }

    // MARK: persistence

    private func persistLive() {
        upsertAndSave(live)
        // saveSessions externalized the big log in allSessions; pull the sanitized
        // copy back into `live` too so memory drops the full inline log and `live`
        // carries rawLogPath (consistent display + export).
        if let s = allSessions.first(where: { $0.id == live.id }) { live = s }
        UserDefaults.standard.set(live.id, forKey: "liveSessionId")
    }
    private func upsertAndSave(_ s: Session) {
        if let i = allSessions.firstIndex(where: { $0.id == s.id }) { allSessions[i] = s }
        else { allSessions.insert(s, at: 0) }
        Store.saveSessions(&allSessions)   // sanitizes in place (externalizes large logs)
    }
    func deleteSession(_ id: String) {
        allSessions.removeAll { $0.id == id }
        Store.saveSessions(&allSessions)
        // Also drop the session's on-disk artifacts: externalized sidecar logs and
        // the per-lane working copies (repo copies can be large). Removing only the
        // JSON entry would leak both under Caches/runs and Application Support/logs.
        let fm = FileManager.default
        try? fm.removeItem(at: Store.logsDir.appendingPathComponent(id, isDirectory: true))
        try? fm.removeItem(at: Workspace.runsRoot.appendingPathComponent(id, isDirectory: true))
        if activeId == id { activeId = "live" }
    }

    // MARK: environment / detection

    func reloadAgents() { AgentCatalog.reload(); bootstrap() }
    func bootstrap() {
        Task {
            let avail = await Detector.scan()
            self.availabilities = avail
            self.scanned = true
            self.applyDefaults()
        }
    }
    // env injected for a lane = the agent's own recipe env (custom agents carry
    // their provider/relay creds baked into the recipe by the config assistant).
    func providerEnv(_ cfg: AgentConfig) -> [String: String] {
        AgentCatalog.spec(cfg.agentId).recipe?.env ?? [:]
    }

    // Meta agent (judge + config assistant) — isolated identity from lanes; its env
    // comes from its own recipe (same baked-in-creds model as lanes).
    var metaBin: String? { path(prefs.metaAgentId) }
    func metaEnv() -> [String: String] {
        AgentCatalog.spec(prefs.metaAgentId).recipe?.env ?? [:]
    }

    private func applyDefaults() {
        let installed = availabilities.filter { $0.installed }.map { $0.spec.id }
        let pick = installed + AgentCatalog.all.map { $0.id }
        if live.runs.allSatisfy({ $0.status == .pending }) {
            let a = pick.first ?? "claude-code"
            let b = pick.first(where: { $0 != a }) ?? (pick.dropFirst().first ?? "codex")
            live.configs = [AgentConfig(agentId: a, model: "", repo: ""), AgentConfig(agentId: b, model: "", repo: "")]
            live.runs = [RunResult(), RunResult()]
            live.judgeAgentId = isInstalled("claude-code") ? "claude-code" : (installed.first ?? "claude-code")
            live.judgeOn = !installed.isEmpty
        }
    }

    func models(for agentId: String) -> [String] {
        let detected = availabilities.first { $0.spec.id == agentId }?.models ?? []
        return detected.isEmpty ? AgentCatalog.spec(agentId).models : detected
    }

    func path(_ agentId: String) -> String? { availabilities.first { $0.spec.id == agentId }?.path }
    func isInstalled(_ agentId: String) -> Bool { path(agentId) != nil }

    // MARK: derived

    var livePhase: Phase {
        let st = live.runs.map { $0.status }
        if st.allSatisfy({ $0 == .pending }) { return .compose }
        if st.contains(.running) { return .running }
        return .done
    }
    var historySessions: [Session] {
        allSessions.filter { $0.id != live.id && $0.isArchived }.sorted { $0.createdAt > $1.createdAt }
    }
    func archived(_ id: String) -> Session? { allSessions.first { $0.id == id } }
    var accentColor: Color { Color(hexString: prefs.accent) }

    // N-way diff vs lane 0 (lane 0 shows its deletions vs lane 1). Results are
    // cached by code content so the O(m·n) LCS runs only when a lane's code
    // actually changes — not on every view-body read while the diff tab is open.
    private var diffCache: [String: (a: [DiffMark], b: [DiffMark])] = [:]
    func diffMap(_ lane: Int) -> [DiffMark]? {
        guard diff, artifactView == "code", live.runs.count >= 2,
              live.runs.indices.contains(lane) else { return nil }
        let codes = live.runs.map { $0.answer?.code ?? "" }
        let other = lane == 0 ? 1 : lane
        let key = "\(codes[0].hashValue)|\(codes[other].hashValue)"
        let pair: (a: [DiffMark], b: [DiffMark])
        if let cached = diffCache[key] {
            pair = cached
        } else {
            if diffCache.count > 32 { diffCache.removeAll() }   // bound long-session growth
            pair = DiffEngine.diff(codes[0], codes[other])
            diffCache[key] = pair
        }
        return lane == 0 ? pair.a : pair.b
    }

    // MARK: lane management (compose)

    func addLane() {
        guard livePhase == .compose, live.configs.count < Lane.maxCount else { return }
        let used = Set(live.configs.map { $0.agentId })
        let pick = (availabilities.filter { $0.installed }.map { $0.spec.id } + AgentCatalog.all.map { $0.id })
            .first { !used.contains($0) } ?? (AgentCatalog.all.first?.id ?? "claude-code")
        live.configs.append(AgentConfig(agentId: pick, model: "", repo: ""))
        live.runs.append(RunResult())
    }
    func removeLane(_ i: Int) {
        guard livePhase == .compose, live.configs.count > Lane.minCount, live.configs.indices.contains(i) else { return }
        live.configs.remove(at: i); live.runs.remove(at: i)
    }

    // MARK: actions

    func newComparison() {
        runTask?.cancel()
        var fresh = Session()
        fresh.configs = live.configs.map { AgentConfig(agentId: $0.agentId, model: $0.model, repo: $0.repo) }
        fresh.runs = fresh.configs.map { _ in RunResult() }
        fresh.judgeOn = live.judgeOn; fresh.judgeAgentId = live.judgeAgentId; fresh.judgeModel = live.judgeModel
        fresh.task = ""
        live = fresh
        activeId = "live"
        artifactView = "preview"; diff = false; judgeOpen = false; compareOpen = false; judging = false
        trustedPreviews = []
        UserDefaults.standard.set(live.id, forKey: "liveSessionId")
    }
    func selectLive() { activeId = "live" }

    func canRun() -> Bool {
        !live.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && live.configs.allSatisfy { isInstalled($0.agentId) }
    }

    func runComparison() {
        guard canRun() else { return }
        runTask?.cancel()
        judgeTask?.cancel()   // a new run supersedes any in-flight manual judge retry

        var s = live
        s.runs = s.configs.map { _ in var r = RunResult(); r.status = .running; return r }
        s.verdict = nil; s.vote = nil
        s.createdAt = Date(); s.finishedAt = nil
        live = s
        activeId = "live"
        artifactView = "preview"; diff = false; compareOpen = false; judgeOpen = false; judging = false
        trustedPreviews = []
        persistLive()

        let sid = s.id, task = s.task
        let auto = prefs.autoApprove, sandbox = prefs.sandboxRuns
        let judgeOn = s.judgeOn

        runTask = Task {
            await self.runLanes(Set(s.configs.indices), task: task, sid: sid, auto: auto, sandbox: sandbox, isInitial: true)
            guard !Task.isCancelled, self.live.id == sid else { return }
            self.persistLive()
            await self.advanceAndJudge(sid: sid, auto: auto, sandbox: sandbox, judgeOn: judgeOn)
        }
    }

    // Run/continue the given lanes in parallel; store each result as it finishes.
    private func runLanes(_ lanes: Set<Int>, task: String, sid: String, auto: Bool, sandbox: Bool,
                          isInitial: Bool, message: String = "") async {
        let cfgs = live.configs
        let bins = cfgs.map { path($0.agentId) }
        let envs = cfgs.map { providerEnv($0) }
        let priors = live.runs
        await withTaskGroup(of: (Int, RunResult).self) { group in
            for i in cfgs.indices {
                let go = lanes.contains(i)
                let cfg = cfgs[i], bin = bins[i], env = envs[i], prior = priors[i]
                group.addTask {
                    if isInitial {
                        return (i, await AppState.runOne(lane: i, cfg: cfg, task: task, sid: sid,
                            auto: auto, sandbox: sandbox, bin: bin, env: env, owner: self))
                    } else {
                        return (i, await AppState.continueMaybe(go, lane: i, prior: prior, cfg: cfg, msg: message,
                            auto: auto, sandbox: sandbox, bin: bin, env: env, sid: sid, owner: self))
                    }
                }
            }
            for await (i, r) in group where live.id == sid && live.runs.indices.contains(i) {
                live.runs[i] = r
            }
        }
    }

    private func advanceAndJudge(sid: String, auto: Bool, sandbox: Bool, judgeOn: Bool,
                                 maxAuto: Int = 3) async {
        if prefs.autoAnswerQuestions {
            var rounds = 0
            while !Task.isCancelled, live.id == sid, rounds < maxAuto {
                let qlanes = live.runs.indices.filter { endsWithQuestion(live.runs[$0]) }
                guard !qlanes.isEmpty else { break }
                rounds += 1
                for i in qlanes {
                    live.runs[i].turns.append(Turn(kind: .user, summary: "你决定（自动应答）"))
                    live.runs[i].status = .running
                }
                await runLanes(Set(qlanes), task: live.task, sid: sid, auto: auto, sandbox: sandbox,
                               isInitial: false, message: "你决定。按你认为最合理的方案继续完成这个任务，不要再问我。")
                guard live.id == sid else { return }
                persistLive()
            }
        }
        if judgeOn, live.runs.allSatisfy({ $0.status == .done }), let judgeBin = metaBin {
            judging = true; live.judgeError = nil
            var outcome = Judge.Outcome(verdict: nil, error: nil)
            for _ in 0..<3 {   // retry transient failures
                outcome = await Judge.run(task: live.task, runs: live.runs,
                                          judgeAgentId: prefs.metaAgentId, judgeModel: prefs.metaModel,
                                          judgeBin: judgeBin, env: metaEnv())
                if outcome.verdict != nil { break }
                if Task.isCancelled || live.id != sid { break }
            }
            if live.id == sid {
                judging = false
                live.verdict = outcome.verdict
                live.judgeError = outcome.verdict == nil ? (outcome.error ?? "裁判未产出结果") : nil
            }
        }
        guard live.id == sid else { return }
        live.finishedAt = Date()
        persistLive()
    }

    func endsWithQuestion(_ run: RunResult) -> Bool {
        guard run.status == .done, let ans = run.answer else { return false }
        let s = ans.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        if s.hasSuffix("?") || s.hasSuffix("？") { return true }
        let lc = s.lowercased()
        let asks = ["请问", "您希望", "你希望", "是否需要", "要我", "需要我", "哪一种", "哪种", "请确认", "请选择", "请提供",
                    "which option", "would you like", "should i", "do you want", "let me know", "please confirm", "please clarify"]
        return ans.files.isEmpty && asks.contains { lc.contains($0.lowercased()) }
    }

    // MARK: multi-turn follow-up

    func sendFollowup(_ lanes: Set<Int>) {
        let msg = followupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard livePhase == .done, !msg.isEmpty else { return }
        let targets = lanes.filter { live.runs.indices.contains($0) && live.runs[$0].status == .done && path(live.configs[$0].agentId) != nil }
        guard !targets.isEmpty else { return }
        followupText = ""
        runTask?.cancel()
        for i in targets { live.runs[i].turns.append(Turn(kind: .user, summary: msg)); live.runs[i].status = .running }
        live.verdict = nil; live.vote = nil
        judgeOpen = false; compareOpen = false

        let sid = live.id, auto = prefs.autoApprove, sandbox = prefs.sandboxRuns
        let judgeOn = live.judgeOn

        runTask = Task {
            await self.runLanes(Set(targets), task: self.live.task, sid: sid, auto: auto, sandbox: sandbox, isInitial: false, message: msg)
            guard !Task.isCancelled, self.live.id == sid else { return }
            self.persistLive()
            await self.advanceAndJudge(sid: sid, auto: auto, sandbox: sandbox, judgeOn: judgeOn)
        }
    }

    // Manually re-run the judge (e.g. after a transient failure).
    func retryJudge() {
        guard livePhase == .done, live.judgeOn, live.runs.allSatisfy({ $0.status == .done }),
              let bin = metaBin, !judging else { return }
        let sid = live.id
        judging = true; live.judgeError = nil
        judgeTask?.cancel()
        judgeTask = Task {
            var outcome = Judge.Outcome(verdict: nil, error: nil)
            for _ in 0..<3 {
                if Task.isCancelled { return }
                outcome = await Judge.run(task: self.live.task, runs: self.live.runs,
                                          judgeAgentId: self.prefs.metaAgentId, judgeModel: self.prefs.metaModel,
                                          judgeBin: bin, env: self.metaEnv())
                if outcome.verdict != nil || self.live.id != sid { break }
            }
            guard !Task.isCancelled, self.live.id == sid else { return }
            self.judging = false
            self.live.verdict = outcome.verdict
            self.live.judgeError = outcome.verdict == nil ? (outcome.error ?? "裁判未产出结果") : nil
            self.persistLive()
        }
    }

    func cancelRun() {
        runTask?.cancel()
        judgeTask?.cancel()
        for i in live.runs.indices where live.runs[i].status == .running {
            live.runs[i].status = .failed; live.runs[i].error = "已取消"
        }
        judging = false
        // persist the canceled state: without finishedAt + a save, the last write
        // (from runComparison) still has lanes as .running, so relaunch restores a
        // stale running session.
        live.finishedAt = live.finishedAt ?? Date()
        persistLive()
    }

    func vote(_ label: String) {
        live.vote = label
        if live.isArchived { persistLive() }
        else if livePhase == .done { live.finishedAt = live.finishedAt ?? Date(); persistLive() }
    }

    func rerun(from h: Session) {
        var fresh = Session()
        fresh.task = h.task
        fresh.configs = h.configs.map { AgentConfig(agentId: $0.agentId, model: $0.model, repo: $0.repo) }
        fresh.runs = fresh.configs.map { _ in RunResult() }
        fresh.judgeOn = h.judgeOn; fresh.judgeAgentId = h.judgeAgentId; fresh.judgeModel = h.judgeModel
        live = fresh
        activeId = "live"
    }

    // MARK: lane runners (nonisolated; stream into live.runs[lane])

    private nonisolated static func runOne(lane: Int, cfg: AgentConfig, task: String, sid: String,
                                           auto: Bool, sandbox: Bool, bin: String?, env: [String: String],
                                           owner: AppState?) async -> RunResult {
        guard let bin else {
            var r = RunResult(); r.status = .failed
            r.error = "未找到 \(AgentCatalog.spec(cfg.agentId).name) CLI（\(AgentCatalog.spec(cfg.agentId).bin)）。\n安装: \(AgentCatalog.spec(cfg.agentId).installHint)"
            return r
        }
        return await AgentRunner.run(config: cfg, task: task, sessionId: sid, lane: lane,
                                     autoApprove: auto, binPath: bin, env: env, sandbox: sandbox) { live in
            Task { @MainActor in
                guard let owner, owner.live.id == sid, owner.live.runs.indices.contains(lane) else { return }
                if owner.live.runs[lane].status == .running { owner.live.runs[lane].turns = live.turns }
            }
        }
    }

    private nonisolated static func continueMaybe(_ go: Bool, lane: Int, prior: RunResult, cfg: AgentConfig,
            msg: String, auto: Bool, sandbox: Bool, bin: String?, env: [String: String],
            sid: String, owner: AppState?) async -> RunResult {
        guard go else { return prior }
        guard let bin else { var r = prior; r.status = .failed; r.error = "未找到 \(AgentCatalog.spec(cfg.agentId).name) CLI"; return r }
        return await AgentRunner.continueRun(prior: prior, config: cfg, message: msg, autoApprove: auto,
                                             binPath: bin, env: env, sandbox: sandbox) { live in
            Task { @MainActor in
                guard let owner, owner.live.id == sid, owner.live.runs.indices.contains(lane) else { return }
                if owner.live.runs[lane].status == .running { owner.live.runs[lane].turns = live.turns }
            }
        }
    }
}
