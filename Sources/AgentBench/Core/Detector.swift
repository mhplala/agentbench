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
            _ = await ProcessRunner.run(executable: path, args: ["models"], cwd: nil) { l in
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
        let code = await ProcessRunner.run(
            executable: path, args: ["--version"], cwd: nil
        ) { line in
            if !line.text.isEmpty { collector.add(line.text + " ") }
        }
        _ = code
        let v = collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return nil }
        // keep it short
        return String(v.prefix(40))
    }
}
