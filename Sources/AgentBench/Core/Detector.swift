import Foundation

struct AgentAvailability: Identifiable, Hashable {
    var id: String { spec.id }
    var spec: AgentSpec
    var path: String?           // resolved binary path, nil if missing
    var version: String?        // best-effort version string
    var models: [String] = []   // REAL models discovered from the CLI (may be empty)
    var installed: Bool { path != nil }
}

// Probes the environment for installed agent CLIs.
enum Detector {
    static func scan() async -> [AgentAvailability] {
        await withTaskGroup(of: AgentAvailability.self) { group in
            for spec in AgentCatalog.all {
                group.addTask {
                    let path = ProcessRunner.which(spec.bin)
                    var version: String? = nil
                    var models: [String] = []
                    if let path {
                        version = await probeVersion(path)
                        models = await fetchModels(spec, path)
                    }
                    return AgentAvailability(spec: spec, path: path, version: version, models: models)
                }
            }
            var out: [AgentAvailability] = []
            for await r in group { out.append(r) }
            // preserve catalog order
            return AgentCatalog.all.compactMap { s in out.first { $0.spec.id == s.id } }
        }
    }

    // Ask the CLI for the models actually available on THIS machine (auth + providers).
    // Returns [] when the CLI offers no machine-readable list — the UI then shows a
    // free-text field defaulting to the agent's own default model.
    private static func fetchModels(_ spec: AgentSpec, _ path: String) async -> [String] {
        switch spec.id {
        case "opencode":
            let collector = TextCollector()
            // Bounded: a CLI that blocks on auth/network/plugin init must not stall
            // bootstrap. On timeout we keep whatever lines arrived (partial list).
            await runBounded(12, executable: path, args: ["models"]) { l in
                let t = l.text.trimmingCharacters(in: .whitespaces)
                if !l.isErr && !t.isEmpty && !t.hasPrefix("█") && !t.hasPrefix("▀")
                    && (t.contains("/") || t.contains(":")) { collector.addLine(t) }
            }
            return Array(collector.value.split(separator: "\n").map(String.init).prefix(200))
        default:
            return []
        }
    }

    private static func probeVersion(_ path: String) async -> String? {
        let collector = TextCollector()
        await runBounded(6, executable: path, args: ["--version"]) { line in
            if !line.text.isEmpty { collector.add(line.text + " ") }
        }
        let v = collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return nil }
        // keep it short
        return String(v.prefix(40))
    }

    // Run a probe with a wall-clock timeout. On timeout the child process is
    // terminated (ProcessRunner honors Task cancellation), so a hung CLI can't
    // keep bootstrap stuck in the "detecting" state.
    private static func runBounded(_ seconds: Double, executable: String, args: [String],
                                   onLine: @escaping @Sendable (ProcessRunner.Line) -> Void) async {
        let runTask = Task { await ProcessRunner.run(executable: executable, args: args, cwd: nil, onLine: onLine) }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            runTask.cancel()
        }
        _ = await runTask.value
        timeout.cancel()
    }
}
