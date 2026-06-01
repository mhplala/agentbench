import Foundation

// Each agent runs in its OWN isolated copy of the working directory so the two
// agents never clobber each other or the user's real repo. After the run we
// compute the agent's changes (git diff when possible, file-snapshot otherwise).
enum Workspace {

    struct Changes {
        var files: [FileChange]
        var unifiedDiff: String       // for the "代码" view
        var primaryCode: String       // best single artifact (diff or new file body)
        var previewHTML: String?      // renderable artifact
        var previewPath: String?
        var linesAdded: Int
        // line count of primaryCode, computed once (allocation-free) so views don't
        // re-split a huge diff on every render
        var codeLines: Int {
            if primaryCode.isEmpty { return 0 }
            var n = 1
            for u in primaryCode.utf8 where u == 0x0A { n += 1 }
            return n
        }
    }

    static var runsRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentBench/runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static let skipDirs: Set<String> = [".git", "node_modules", ".next", "dist",
        "build", ".venv", "venv", "__pycache__", ".DS_Store", "target", ".turbo", ".cache"]

    // Create an isolated copy (or empty scratch dir) and return its path + whether it's a git repo.
    static func prepare(repo: String, sessionId: String, lane: Int) throws -> (dir: String, isGit: Bool) {
        let fm = FileManager.default
        let dest = runsRoot
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(Lane.label(lane), isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }

        let trimmed = (repo as NSString).expandingTildeInPath
        if trimmed.isEmpty || repo.isEmpty {
            // scratch workspace — the agent's produced files ARE the artifact
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            return (dest.path, false)
        }
        guard fm.fileExists(atPath: trimmed) else {
            throw NSError(domain: "AgentBench", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "工作目录不存在: \(trimmed)"])
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // rsync first so heavy *derived* dirs (node_modules / build / .next / venv …)
        // are skipped — copying a real frontend repo otherwise duplicates hundreds of
        // MB per lane. `.git` is kept so the git-diff path still works. Falls back to
        // an APFS clone (COW) / plain copy if rsync is unavailable or fails.
        var cloned = rsyncCopy(trimmed, dest.path) == 0
        if !cloned {
            try? fm.removeItem(at: dest)
            cloned = cp(["-Rc", trimmed, dest.path]) == 0 || cp(["-R", trimmed, dest.path]) == 0
        }
        guard cloned else {
            throw NSError(domain: "AgentBench", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法复制工作目录到隔离副本"])
        }
        let isGit = fm.fileExists(atPath: dest.appendingPathComponent(".git").path)
        if isGit { gitBaseline(dest.path) }
        return (dest.path, isGit)
    }

    // Commit the current state as a baseline so the next diff captures only the
    // changes made after this point (used before the first run and each follow-up).
    static func gitBaseline(_ dir: String) {
        _ = git(dir, ["add", "-A"])
        _ = git(dir, ["commit", "-m", "agentbench-baseline", "--no-verify", "--allow-empty"])
    }

    static func isGitRepo(_ dir: String) -> Bool {
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
    }

    // Snapshot file modification signatures before a run (used for non-git dirs).
    static func snapshot(_ dir: String) -> [String: String] {
        var map: [String: String] = [:]
        for url in walk(dir) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            map[rel(url.path, dir)] = "\(size)-\(mtime)"
        }
        return map
    }

    static func collectChanges(dir: String, isGit: Bool, before: [String: String]) -> Changes {
        if isGit { return gitChanges(dir: dir) }
        return fileChanges(dir: dir, before: before)
    }

    // MARK: git-based

    private static func gitChanges(dir: String) -> Changes {
        _ = git(dir, ["add", "-A"])
        // diff against the baseline commit so pre-existing work is excluded
        let base = git(dir, ["rev-parse", "--verify", "HEAD"]).code == 0 ? "HEAD" : "--cached"
        let numstat = git(dir, ["diff", base, "--numstat"]).out
        var files: [FileChange] = []
        var totalAdd = 0
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            files.append(FileChange(path: parts[2], add: add, del: del))
            totalAdd += add
        }
        let unified = git(dir, ["diff", base]).out
        let (html, htmlPath) = findPreview(dir: dir, changed: files.map { $0.path })
        let primary = unified.isEmpty ? (html ?? "（无改动）") : unified
        return Changes(files: files, unifiedDiff: unified, primaryCode: primary,
                       previewHTML: html, previewPath: htmlPath, linesAdded: totalAdd)
    }

    // MARK: snapshot-based (scratch or non-git)

    private static func fileChanges(dir: String, before: [String: String]) -> Changes {
        let after = snapshot(dir)
        var changedPaths: [String] = []
        for (path, sig) in after where before[path] != sig {
            changedPaths.append(path)
        }
        changedPaths.sort()
        var files: [FileChange] = []
        var diffChunks: [String] = []
        var totalAdd = 0
        var primary = ""
        for p in changedPaths {
            let full = (dir as NSString).appendingPathComponent(p)
            guard let body = try? String(contentsOfFile: full, encoding: .utf8) else {
                files.append(FileChange(path: p, add: 0, del: 0)); continue
            }
            let lineCount = body.isEmpty ? 0 : body.components(separatedBy: "\n").count
            let isNew = before[p] == nil
            files.append(FileChange(path: p, add: lineCount, del: 0))
            totalAdd += lineCount
            diffChunks.append("\(isNew ? "+++ 新建" : "~~~ 修改") \(p)\n" +
                body.components(separatedBy: "\n").map { "+ " + $0 }.joined(separator: "\n"))
            if primary.isEmpty && !p.hasSuffix(".lock") && !p.hasSuffix(".json") {
                primary = body
            }
        }
        // deletions: paths present before the run but gone after
        let deletedPaths = before.keys.filter { after[$0] == nil }.sorted()
        for p in deletedPaths {
            files.append(FileChange(path: p, add: 0, del: 0, deleted: true))
            diffChunks.append("--- 删除 \(p)")
        }

        let (html, htmlPath) = findPreview(dir: dir, changed: changedPaths)
        if primary.isEmpty { primary = html ?? diffChunks.first ?? "（无产出文件）" }
        return Changes(files: files, unifiedDiff: diffChunks.joined(separator: "\n\n"),
                       primaryCode: primary, previewHTML: html, previewPath: htmlPath,
                       linesAdded: totalAdd)
    }

    // MARK: helpers

    private static func findPreview(dir: String, changed: [String]) -> (String?, String?) {
        // prefer changed html, then index.html, then any html in the tree
        let htmlChanged = changed.filter { $0.lowercased().hasSuffix(".html") }
        let candidates = htmlChanged
            + htmlChanged.filter { $0.lowercased().hasSuffix("index.html") }
        var pick = candidates.first
        if pick == nil {
            pick = walk(dir).first { $0.path.lowercased().hasSuffix(".html") }
                .map { rel($0.path, dir) }
        }
        guard let rp = pick else { return (nil, nil) }
        let full = (dir as NSString).appendingPathComponent(rp)
        let body = try? String(contentsOfFile: full, encoding: .utf8)
        return (body, rp)
    }

    private static func walk(_ dir: String) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if skipDirs.contains(url.lastPathComponent) {
                en.skipDescendants(); continue
            }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile { out.append(url) }
        }
        return out
    }

    private static func rel(_ path: String, _ base: String) -> String {
        var p = path
        let b = base.hasSuffix("/") ? base : base + "/"
        if p.hasPrefix(b) { p.removeFirst(b.count) }
        return p
    }

    // Copy a tree excluding heavy derived dirs (keeps .git). Returns rsync's status.
    private static func rsyncCopy(_ src: String, _ dest: String) -> Int32 {
        var args = ["-a"]
        for d in skipDirs.subtracting([".git"]) { args += ["--exclude", d] }
        args += [src.hasSuffix("/") ? src : src + "/", dest]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = args
        p.standardError = Pipe(); p.standardOutput = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
        catch { return 1 }
    }

    @discardableResult
    private static func cp(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = args
        p.standardError = Pipe(); p.standardOutput = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
        catch { return 1 }
    }

    @discardableResult
    private static func git(_ dir: String, _ args: [String]) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir,
                       "-c", "user.email=agentbench@local",
                       "-c", "user.name=AgentBench",
                       "-c", "commit.gpgsign=false"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"; env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
        } catch { return ("", 1) }
    }
}
