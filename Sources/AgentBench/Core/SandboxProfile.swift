import Foundation

// Builds a macOS seatbelt profile that confines an agent's WRITES to its
// workspace (+ temp and the CLIs' own cache/config dirs), while still allowing
// full read, network (needed to reach the model API), and process execution.
// The whole process tree the agent spawns inherits this sandbox.
enum SandboxProfile {
    static func make(workdir: String) -> String {
        let home = NSHomeDirectory()
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }
        let writable = [
            workdir,
            "/tmp", "/private/tmp", "/var/folders", "/private/var/folders",
            "\(home)/Library/Caches",
            "\(home)/Library/Application Support",
            "\(home)/Library/Logs",
            "\(home)/.claude", "\(home)/.codex", "\(home)/.gemini",
            "\(home)/.config", "\(home)/.cache", "\(home)/.npm",
            "\(home)/.cursor", "\(home)/.aider", "\(home)/.local",
            "/dev",
        ]
        let writeRules = writable.map { "  (subpath \"\(esc($0))\")" }.joined(separator: "\n")
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        (allow file-write*
        \(writeRules)
          (literal "/dev/null") (literal "/dev/zero") (literal "/dev/random") (literal "/dev/urandom"))
        """
    }
}
