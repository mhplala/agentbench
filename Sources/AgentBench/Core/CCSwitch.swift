import Foundation
import SQLite3

// Integrates cc-switch (https://github.com/farion1231/cc-switch): reads the
// provider configs it manages (~/.cc-switch/cc-switch.db) so you can run an agent
// against any configured provider/relay — even the SAME agent on two providers
// side by side — by injecting that provider's env into the run subprocess.
struct CCProvider: Identifiable, Hashable {
    var id: String           // providers.id
    var appType: String      // claude | codex | gemini | opencode …
    var agentId: String      // mapped to our catalog id
    var name: String
    var env: [String: String]
    var baseUrl: String?
    var token: String?
    var healthy: Bool?       // cc-switch's recorded health
    var healthError: String?

    var isDefault: Bool { env.isEmpty }          // {} = use the tool's ambient config
    var injectable: Bool { !env.isEmpty }        // we can override via env
}

enum CCSwitch {
    static var dbURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cc-switch/cc-switch.db")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: dbURL.path) }

    static func appTypeToAgentId(_ t: String) -> String? {
        switch t {
        case "claude": return "claude-code"
        case "codex": return "codex"
        case "gemini": return "gemini"
        case "opencode": return "opencode"
        default: return nil   // claude-desktop etc. — not a CLI agent here
        }
    }

    static func loadProviders() -> [CCProvider] {
        guard isInstalled else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT p.id, p.app_type, p.name, p.settings_config, h.is_healthy, h.last_error
        FROM providers p
        LEFT JOIN provider_health h ON p.id = h.provider_id AND p.app_type = h.app_type
        ORDER BY p.app_type, p.sort_index
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }

        var out: [CCProvider] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let appType = text(1) ?? ""
            guard let agentId = appTypeToAgentId(appType) else { continue }
            let id = text(0) ?? UUID().uuidString
            let name = text(2) ?? "未命名"
            let cfgJSON = text(3) ?? "{}"
            let healthyRaw = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 4)
            let env = parseEnv(cfgJSON)
            out.append(CCProvider(
                id: id, appType: appType, agentId: agentId, name: name, env: env,
                baseUrl: env["ANTHROPIC_BASE_URL"] ?? env["OPENAI_BASE_URL"] ?? env["GOOGLE_GEMINI_BASE_URL"],
                token: env["ANTHROPIC_AUTH_TOKEN"] ?? env["ANTHROPIC_API_KEY"] ?? env["OPENAI_API_KEY"],
                healthy: healthyRaw.map { $0 != 0 },
                healthError: text(5)))
        }
        return out
    }

    private static func parseEnv(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = obj["env"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in env { if let s = v as? String, !s.isEmpty { out[k] = s } }
        return out
    }

    // MARK: connectivity test (通过性)

    enum TestResult { case ok(String), authFail(String), reachable(String), down(String), skip(String)
        var passed: Bool { if case .ok = self { return true }; return false }
        var label: String {
            switch self {
            case .ok(let s): return "通过 · \(s)"
            case .authFail(let s): return "鉴权失败 · \(s)"
            case .reachable(let s): return "可达 · \(s)"
            case .down(let s): return "不通 · \(s)"
            case .skip(let s): return s
            }
        }
    }

    static func test(_ p: CCProvider) async -> TestResult {
        guard let base = p.baseUrl, let url = URL(string: base.hasSuffix("/") ? base + "v1/models" : base + "/v1/models") else {
            return .skip("默认配置 · 无需测试")
        }
        var req = URLRequest(url: url, timeoutInterval: 9)
        if let t = p.token {
            req.setValue(t, forHTTPHeaderField: "x-api-key")
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let start = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200...299: return .ok("HTTP \(code) · \(ms)ms")
            case 401, 403:  return .authFail("HTTP \(code)")
            default:        return .reachable("HTTP \(code) · \(ms)ms")   // host up, endpoint differs
            }
        } catch {
            return .down((error as NSError).localizedDescription)
        }
    }
}
