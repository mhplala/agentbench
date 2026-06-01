import Foundation

// Persists finished sessions to Application Support as JSON. No mock data — the
// history starts empty and fills as the user runs real comparisons.
enum Store {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentBench", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static var sessionsURL: URL { dir.appendingPathComponent("sessions.json") }
    static var logsDir: URL {
        let u = dir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    // Logs longer than this are written to a sidecar .log file; only the tail stays
    // inline in sessions.json so the JSON (loaded fully at launch) can't balloon.
    private static let rawLogInlineCap = 64 * 1024

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func loadSessions() -> [Session] {
        guard let data = try? Data(contentsOf: sessionsURL) else { return [] }
        return (try? decoder.decode([Session].self, from: data)) ?? []
    }

    // Externalizes oversized raw logs to sidecar .log files and writes the JSON.
    // Mutates `sessions` IN PLACE (inout) so the caller's canonical state (allSessions/
    // live) also drops the huge inline log and gains rawLogPath — otherwise the in-
    // memory copy keeps the full log forever and every save re-writes the sidecar.
    static func saveSessions(_ sessions: inout [Session]) {
        for si in sessions.indices {
            for ri in sessions[si].runs.indices {
                let full = sessions[si].runs[ri].rawLog
                // already externalized (tail marker under the cap) → nothing to do
                guard full.utf8.count > rawLogInlineCap else { continue }
                let rel = "logs/\(sessions[si].id)/\(Lane.label(ri)).log"
                let fileURL = dir.appendingPathComponent(rel)
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? full.write(to: fileURL, atomically: true, encoding: .utf8)
                sessions[si].runs[ri].rawLogPath = rel
                // keep only the tail inline for in-app display (full log lives in the sidecar)
                let tail = String(full.suffix(rawLogInlineCap / 2))
                sessions[si].runs[ri].rawLog = "…（前文已外置，完整日志见 \(rel)）\n" + tail
            }
        }
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    // Read the complete raw log for a run: the externalized sidecar if present,
    // otherwise the inline field (small logs that were never externalized).
    static func fullRawLog(_ run: RunResult) -> String {
        if let rel = run.rawLogPath,
           let full = try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8) {
            return full
        }
        return run.rawLog
    }
}

// User preferences backed by UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var accent: String { didSet { d.set(accent, forKey: "accent") } }
    @Published var density: String { didSet { d.set(density, forKey: "density") } }  // compact | regular
    @Published var showThinking: Bool { didSet { d.set(showThinking, forKey: "showThinking") } }
    @Published var autoApprove: Bool { didSet { d.set(autoApprove, forKey: "autoApprove") } }
    // run JS + load sibling assets for locally-produced artifact previews by default
    @Published var trustLocalPreviews: Bool { didSet { d.set(trustLocalPreviews, forKey: "trustLocalPreviews") } }
    // when a round ends by asking a question, auto-reply "你决定" to keep it progressing
    @Published var autoAnswerQuestions: Bool { didSet { d.set(autoAnswerQuestions, forKey: "autoAnswerQuestions") } }
    // confine each agent run (writes limited to its workspace copy + temp + caches)
    @Published var sandboxRuns: Bool { didSet { d.set(sandboxRuns, forKey: "sandboxRuns") } }

    // "Meta" agent used for judging + the config assistant — kept separate from the
    // benchmarked lanes so its identity/credits don't mix with contestants.
    @Published var metaAgentId: String { didSet { d.set(metaAgentId, forKey: "metaAgentId") } }
    @Published var metaModel: String { didSet { d.set(metaModel, forKey: "metaModel") } }
    // extra env vars injected into every agent run (e.g. ARK_API_KEY / OPENAI_API_KEY
    // that a provider's config references via env_key but the GUI env lacks)
    @Published var customEnv: [String: String] { didSet { d.set(customEnv, forKey: "customEnv") } }

    private init() {
        accent = d.string(forKey: "accent") ?? "#111111"
        density = d.string(forKey: "density") ?? "regular"
        showThinking = d.object(forKey: "showThinking") as? Bool ?? true
        autoApprove = d.object(forKey: "autoApprove") as? Bool ?? true
        trustLocalPreviews = d.object(forKey: "trustLocalPreviews") as? Bool ?? true
        autoAnswerQuestions = d.object(forKey: "autoAnswerQuestions") as? Bool ?? true
        sandboxRuns = d.object(forKey: "sandboxRuns") as? Bool ?? true
        metaAgentId = d.string(forKey: "metaAgentId") ?? "claude-code"
        metaModel = d.string(forKey: "metaModel") ?? ""
        customEnv = (d.dictionary(forKey: "customEnv") as? [String: String]) ?? [:]
    }
}
