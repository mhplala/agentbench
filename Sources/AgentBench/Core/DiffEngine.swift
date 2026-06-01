import Foundation

enum DiffMark: Equatable { case add, del, same }

// Git-style line diff via LCS, ported from the prototype's diffLines().
// Returns per-line marks for A (deletions) and B (additions).
enum DiffEngine {
    // The LCS DP table is O(m·n) in time AND memory. Above this many cells we skip
    // it and fall back to a cheap positional compare, so a huge artifact (e.g. a
    // 10k-line file) can never freeze the UI or blow memory (1e8 cells ≈ 800MB).
    static let maxCells = 2_000_000          // ~1400×1400
    static let maxLines = 20_000

    static func diff(_ aText: String, _ bText: String) -> (a: [DiffMark], b: [DiffMark]) {
        let a = aText.components(separatedBy: "\n")
        let b = bText.components(separatedBy: "\n")
        let norm: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        let m = a.count, n = b.count
        if m == 0 && n == 0 { return ([], []) }

        // Degrade gracefully for very large inputs. The `||` short-circuits before
        // `m * n` so the multiplication can't overflow when m or n is enormous.
        if m > maxLines || n > maxLines || m * n > maxCells {
            return positional(a, b, norm)
        }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    dp[i][j] = norm(a[i]) == norm(b[j])
                        ? dp[i + 1][j + 1] + 1
                        : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var aMap = Array(repeating: DiffMark.del, count: m)
        var bMap = Array(repeating: DiffMark.add, count: n)
        var i = 0, j = 0
        while i < m && j < n {
            if norm(a[i]) == norm(b[j]) {
                aMap[i] = .same; bMap[j] = .same; i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (aMap, bMap)
    }

    // O(min(m,n)) fallback: compare lines at the same index. Loses true alignment
    // but is instant and good enough to colour a too-large diff without freezing.
    private static func positional(_ a: [String], _ b: [String], _ norm: (String) -> String) -> (a: [DiffMark], b: [DiffMark]) {
        var aMap = Array(repeating: DiffMark.del, count: a.count)
        var bMap = Array(repeating: DiffMark.add, count: b.count)
        for k in 0..<min(a.count, b.count) where norm(a[k]) == norm(b[k]) {
            aMap[k] = .same; bMap[k] = .same
        }
        return (aMap, bMap)
    }
}
