import Foundation

// MARK: - Agent configuration for one lane

struct AgentConfig: Codable, Hashable {
    var agentId: String          // e.g. "claude-code"
    var model: String            // e.g. "claude-sonnet-4-6" (empty = agent default)
    var repo: String             // working directory / repo; empty = scratch workspace

    static let empty = AgentConfig(agentId: "claude-code", model: "", repo: "")
}

// MARK: - Conversation turns (the dual-column transcript)

enum ToolKind: String, Codable { case read, edit, shell, done, info }

struct ToolStep: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: ToolKind
    var label: String
    var detail: String
}

enum TurnKind: String, Codable { case think, tool, answer, user }

struct Turn: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: TurnKind
    // think
    var plan: [String] = []
    // tool
    var tool: ToolStep? = nil
    // answer
    var summary: String = ""
    var files: [FileChange] = []
    var code: String = ""            // primary code / unified diff to show in "代码"
    var codeLines: Int = 0           // cached line count of `code` (avoid re-splitting big diffs in views)
    var previewHTML: String? = nil   // renderable artifact, if any
    var previewPath: String? = nil   // file path that produced the preview

    // Line count for the "N 行" label. Uses the cached value when present; falls
    // back to an allocation-free, capped newline scan for legacy/decoded turns
    // (never .components(separatedBy:) which allocates the whole split array).
    var codeLineCount: Int {
        if codeLines > 0 { return codeLines }
        if code.isEmpty { return 0 }
        var n = 1, scanned = 0
        for u in code.utf8 {
            if u == 0x0A { n += 1 }
            scanned += 1
            if scanned > 500_000 { break }   // cap: don't scan pathologically huge diffs
        }
        return n
    }
}

struct FileChange: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var add: Int
    var del: Int
    var deleted: Bool? = nil   // true = file removed by the agent (optional for back-compat)
}

// MARK: - Metrics

struct Metrics: Codable, Hashable {
    var latencyMs: Int = 0
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var costUsd: Double = 0
    var lines: Int = 0            // lines added across the diff
    var turns: Int = 0
    var toolCalls: Int = 0
    var tokensEstimated: Bool = false  // true when tokens were char-estimated, not reported
    var costKnown: Bool = true         // false when cost couldn't be determined

    var tokensTotal: Int { tokensIn + tokensOut }
}

// MARK: - A single agent's run result

enum RunStatus: String, Codable { case pending, running, done, failed }

struct RunResult: Codable, Hashable {
    var status: RunStatus = .pending
    var turns: [Turn] = []
    var metrics = Metrics()
    var rawLog: String = ""        // captured stdout/stderr (tail kept inline when large)
    var rawLogPath: String? = nil  // relative path (under Store.dir) to the full log, when externalized
    var error: String? = nil
    var workdir: String = ""       // isolated copy where the agent ran
    var sessionId: String? = nil   // CLI session/thread id, for multi-turn resume

    var answer: Turn? { turns.last(where: { $0.kind == .answer }) }

    // Base directory for resolving a preview's relative assets — the folder that
    // actually contains the HTML file (handles nested e.g. site/index.html).
    var previewBaseDir: String? {
        guard !workdir.isEmpty else { return nil }
        if let rel = answer?.previewPath, !rel.isEmpty {
            let sub = (rel as NSString).deletingLastPathComponent
            return sub.isEmpty ? workdir : (workdir as NSString).appendingPathComponent(sub)
        }
        return workdir
    }

    // The actual HTML file on disk (so trusted previews can load sibling assets).
    var previewFileURL: URL? {
        guard !workdir.isEmpty, let rel = answer?.previewPath, !rel.isEmpty else { return nil }
        return URL(fileURLWithPath: (workdir as NSString).appendingPathComponent(rel))
    }
}

// MARK: - Lanes (2-4 agents compared side by side)

enum Lane {
    static let labels = ["A", "B", "C", "D", "E", "F"]
    static func label(_ i: Int) -> String { i < labels.count ? labels[i] : "\(i + 1)" }
    static let maxCount = 4
    static let minCount = 2
}

// MARK: - Judge verdict (N-way)

struct Criterion: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var scores: [Int]              // one score per lane
    var note: String
    // back-compat accessors
    var a: Int { scores.indices.contains(0) ? scores[0] : 0 }
    var b: Int { scores.indices.contains(1) ? scores[1] : 0 }
}

struct Verdict: Codable, Hashable {
    var judge: String              // who judged
    var winner: String             // lane label "A".."D" or "tie"
    var scores: [Double]           // overall score per lane
    var criteria: [Criterion]
    var rationale: String
}

// MARK: - A full comparison session (one task, two agents)

struct Session: Codable, Hashable, Identifiable {
    var id: String = "cmp_" + UUID().uuidString.prefix(8).lowercased()
    var task: String = ""
    var configs: [AgentConfig] = [
        AgentConfig(agentId: "claude-code", model: "", repo: ""),
        AgentConfig(agentId: "opencode", model: "", repo: ""),
    ]
    var judgeOn: Bool = true
    var judgeAgentId: String = "claude-code"
    var judgeModel: String = ""

    var runs: [RunResult] = [RunResult(), RunResult()]
    var verdict: Verdict? = nil
    var judgeError: String? = nil    // why the judge failed (transient, not persisted)
    var vote: String? = nil          // lane label "A".."D" or "tie"

    var createdAt: Date = Date()
    var finishedAt: Date? = nil

    var laneCount: Int { configs.count }
    // Safe lane indices for views: configs and runs can momentarily desync
    // (imported/exported JSON, transient mutations), and indexing runs[i] off
    // configs.indices would crash. Always iterate the intersection.
    var laneIndices: Range<Int> { 0..<min(configs.count, runs.count) }
    var isArchived: Bool { finishedAt != nil }

    // Sidebar grouping label, derived from createdAt.
    var groupLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(createdAt) { return "今天" }
        if cal.isDateInYesterday(createdAt) { return "昨天" }
        let days = cal.dateComponents([.day], from: createdAt, to: Date()).day ?? 0
        return days <= 7 ? "本周" : "更早"
    }

    var dateLabel: String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(createdAt) || cal.isDateInYesterday(createdAt) {
            f.dateFormat = "HH:mm"
            let prefix = cal.isDateInYesterday(createdAt) ? "昨天 " : ""
            return prefix + f.string(from: createdAt)
        }
        f.dateFormat = "MM-dd"
        return f.string(from: createdAt)
    }
}

// Tolerant Codable (in an extension to preserve the memberwise / no-arg init):
// any missing field decodes to its default, so adding fields never wipes history.
extension Session {
    enum CodingKeys: String, CodingKey {
        case id, task, configs, judgeOn, judgeAgentId, judgeModel
        case runs, verdict, vote, createdAt, finishedAt
        case cfgA, cfgB, runA, runB   // legacy
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .id) { id = v }
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        judgeOn = try c.decodeIfPresent(Bool.self, forKey: .judgeOn) ?? true
        judgeAgentId = try c.decodeIfPresent(String.self, forKey: .judgeAgentId) ?? "claude-code"
        judgeModel = try c.decodeIfPresent(String.self, forKey: .judgeModel) ?? ""
        verdict = try c.decodeIfPresent(Verdict.self, forKey: .verdict)
        // vote was an enum {A,tie,B}; now a label string — both decode as String
        vote = try? c.decodeIfPresent(String.self, forKey: .vote)
        if let v = try c.decodeIfPresent(Date.self, forKey: .createdAt) { createdAt = v }
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)

        // new array form, else migrate from legacy cfgA/cfgB + runA/runB
        if let cfgs = try c.decodeIfPresent([AgentConfig].self, forKey: .configs), !cfgs.isEmpty {
            configs = cfgs
        } else {
            var cs: [AgentConfig] = []
            if let a = try c.decodeIfPresent(AgentConfig.self, forKey: .cfgA) { cs.append(a) }
            if let b = try c.decodeIfPresent(AgentConfig.self, forKey: .cfgB) { cs.append(b) }
            if !cs.isEmpty { configs = cs }
        }
        if let rs = try c.decodeIfPresent([RunResult].self, forKey: .runs), !rs.isEmpty {
            runs = rs
        } else {
            var rs: [RunResult] = []
            if let a = try c.decodeIfPresent(RunResult.self, forKey: .runA) { rs.append(a) }
            if let b = try c.decodeIfPresent(RunResult.self, forKey: .runB) { rs.append(b) }
            if !rs.isEmpty { runs = rs }
        }
        // keep runs aligned with configs
        while runs.count < configs.count { runs.append(RunResult()) }
        if runs.count > configs.count { runs = Array(runs.prefix(configs.count)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(task, forKey: .task)
        try c.encode(configs, forKey: .configs)
        try c.encode(judgeOn, forKey: .judgeOn)
        try c.encode(judgeAgentId, forKey: .judgeAgentId)
        try c.encode(judgeModel, forKey: .judgeModel)
        try c.encode(runs, forKey: .runs)
        try c.encodeIfPresent(verdict, forKey: .verdict)
        try c.encodeIfPresent(vote, forKey: .vote)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
    }
}
