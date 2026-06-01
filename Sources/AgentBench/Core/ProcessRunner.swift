import Foundation

// Lightweight async wrapper around Foundation.Process.
//
// GUI apps launched from Finder do NOT inherit the login-shell PATH, so we
// augment PATH with the usual install locations and resolve binaries through a
// login shell. Output is streamed line-by-line via an async callback.
enum ProcessRunner {

    struct Line { var text: String; var isErr: Bool }

    // Common locations agent CLIs land in, prepended to whatever PATH we inherited.
    static func augmentedPATH() -> String {
        let home = NSHomeDirectory()
        let extra = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin",
            "\(home)/.deno/bin", "\(home)/go/bin", "\(home)/.npm-global/bin",
            "\(home)/.volta/bin", "\(home)/Library/pnpm",
        ]
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var seen = Set<String>()
        let merged = (extra + inherited.split(separator: ":").map(String.init))
            .filter { seen.insert($0).inserted }
        return merged.joined(separator: ":")
    }

    // The user's login-shell environment (sourcing ~/.zprofile/~/.zshrc), captured
    // once. GUI-launched apps don't inherit it, so keys the user exports there
    // (ARK_API_KEY, OPENAI_API_KEY, …) would otherwise be missing from agents.
    static let loginEnv: [String: String] = captureLoginEnv()
    private static func captureLoginEnv() -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "env"]
        p.environment = ProcessInfo.processInfo.environment
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var map: [String: String] = [:]
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let k = String(line[line.startIndex..<eq])
                let v = String(line[line.index(after: eq)...])
                if !k.isEmpty { map[k] = v }
            }
            return map
        } catch { return [:] }
    }

    static func baseEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // fill in vars the user exports in their shell profile but the GUI process
        // didn't inherit (or inherited empty) — e.g. ARK_API_KEY, OPENAI_API_KEY
        for (k, v) in loginEnv where (env[k] == nil || env[k]!.isEmpty) && !v.isEmpty {
            env[k] = v
        }
        env["PATH"] = augmentedPATH()
        // Force non-interactive, no color where honored.
        env["CI"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"

        // An EMPTY auth var is worse than unset: agents treat "" as a (bad) key and
        // 401 instead of falling back to their normal login. Drop empty ones so the
        // CLI uses its own auth (OAuth/keychain); real keys are injected per-provider.
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL"] {
            if let v = env[k], v.isEmpty { env.removeValue(forKey: k) }
        }
        // Don't leak the host Claude-Code session markers into spawned agents
        // (they can confuse a nested claude / change its behavior).
        for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                  "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_TMPDIR", "CLAUDE_AGENT_SDK_VERSION",
                  "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH", "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH",
                  "CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL", "CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES",
                  "CLAUDE_EFFORT", "AI_AGENT", "BAGGAGE"] {
            env.removeValue(forKey: k)
        }
        // user-defined env vars (settings) always win — e.g. ARK_API_KEY for codex
        if let custom = UserDefaults.standard.dictionary(forKey: "customEnv") as? [String: String] {
            for (k, v) in custom where !k.isEmpty { env[k] = v }
        }
        return env
    }

    // Resolve a binary to a full path using a login shell (so version managers,
    // asdf shims, etc. resolve exactly as in the user's terminal). Falls back to
    // scanning the augmented PATH directly.
    static func which(_ bin: String) -> String? {
        // direct scan first (fast, no shell)
        for dir in augmentedPATH().split(separator: ":") {
            let p = String(dir) + "/" + bin
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // login-shell fallback
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v \(bin) 2>/dev/null"]
        p.environment = baseEnv()
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty ? nil : s.split(separator: "\n").first.map(String.init)
        } catch { return nil }
    }

    // Run a command, streaming each stdout/stderr line to `onLine`. Returns the
    // exit code. Honors Task cancellation by terminating the process.
    @discardableResult
    static func run(
        executable: String,
        args: [String],
        cwd: String?,
        extraEnv: [String: String] = [:],
        stdin: String? = nil,
        onLine: @escaping @Sendable (Line) -> Void
    ) async -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let cwd, !cwd.isEmpty { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = baseEnv()
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        let outBuf = LineBuffer(isErr: false, sink: onLine)
        let errBuf = LineBuffer(isErr: true, sink: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            outBuf.feed(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            errBuf.feed(d)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                proc.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outBuf.flush(); errBuf.flush()
                    cont.resume(returning: p.terminationStatus)
                }
                do {
                    try proc.run()
                    if let stdin {
                        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
                    }
                    try? inPipe.fileHandleForWriting.close()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    onLine(Line(text: "无法启动 \(executable): \(error.localizedDescription)", isErr: true))
                    cont.resume(returning: 127)
                }
            }
        } onCancel: {
            // SIGTERM first; a CLI that traps/ignores it would otherwise leave the
            // termination handler (and thus the awaiting task) hung forever. Escalate
            // to SIGKILL on the direct child after a grace period so the continuation
            // is guaranteed to resume.
            proc.terminate()
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

// Thread-safe text accumulator for collecting output from @Sendable callbacks.
final class TextCollector: @unchecked Sendable {
    private var s = ""
    private let lock = NSLock()
    func add(_ t: String) { lock.lock(); s += t; lock.unlock() }
    func addLine(_ t: String) { lock.lock(); s += t + "\n"; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return s }
}

// Splits a byte stream into UTF-8 lines, thread-safe.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let isErr: Bool
    private let sink: @Sendable (ProcessRunner.Line) -> Void
    private let lock = NSLock()

    init(isErr: Bool, sink: @escaping @Sendable (ProcessRunner.Line) -> Void) {
        self.isErr = isErr; self.sink = sink
    }

    func feed(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<nl)
            data.removeSubrange(data.startIndex...nl)
            emit(lineData)
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        if !data.isEmpty { emit(data); data.removeAll() }
        lock.unlock()
    }

    private func emit(_ d: Data) {
        var s = String(data: d, encoding: .utf8) ?? ""
        if s.hasSuffix("\r") { s.removeLast() }
        sink(ProcessRunner.Line(text: s, isErr: isErr))
    }
}
