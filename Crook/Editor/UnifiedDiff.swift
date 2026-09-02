import Foundation

/// A read-only account of what changed. Not a merge tool.
///
/// Crook never accepts, rejects, or stages a hunk. The file on disk is the
/// file — Claude Code wrote it and it is authoritative. What the reader needs
/// is to SEE what moved, which is a different job with a much smaller surface.
/// If they want the old text back they can copy it out of here.
enum UnifiedDiff {

    struct Line {
        enum Kind { case context, added, removed, gap }
        let kind: Kind
        let text: String
        let oldNo: Int?
        let newNo: Int?
    }

    struct Summary {
        let added: Int
        let removed: Int
        var isEmpty: Bool { added == 0 && removed == 0 }
    }

    static func between(_ old: String, _ new: String, context: Int = 3) -> ([Line], Summary) {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")

        // Trim the common ends first. A contiguous rewrite — the usual shape —
        // collapses to a tiny middle, which keeps the LCS below cheap.
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }

        let midA = Array(a[head..<(a.count - tail)])
        let midB = Array(b[head..<(b.count - tail)])

        var ops: [Line] = []
        var added = 0, removed = 0

        // Guard against a pathological middle: a whole-file rewrite of a large
        // document would be O(n*m). Past the cap, report it as a block replace
        // rather than spending seconds to say the same thing.
        if midA.count * midB.count > 400_000 {
            for (i, l) in midA.enumerated() {
                ops.append(Line(kind: .removed, text: l, oldNo: head + i + 1, newNo: nil)); removed += 1
            }
            for (i, l) in midB.enumerated() {
                ops.append(Line(kind: .added, text: l, oldNo: nil, newNo: head + i + 1)); added += 1
            }
        } else {
            // LCS over the middle only.
            let n = midA.count, m = midB.count
            var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        lcs[i][j] = midA[i] == midB[j]
                            ? lcs[i + 1][j + 1] + 1
                            : max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if midA[i] == midB[j] {
                    ops.append(Line(kind: .context, text: midA[i], oldNo: head + i + 1, newNo: head + j + 1))
                    i += 1; j += 1
                } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                    ops.append(Line(kind: .removed, text: midA[i], oldNo: head + i + 1, newNo: nil))
                    removed += 1; i += 1
                } else {
                    ops.append(Line(kind: .added, text: midB[j], oldNo: nil, newNo: head + j + 1))
                    added += 1; j += 1
                }
            }
            while i < n { ops.append(Line(kind: .removed, text: midA[i], oldNo: head + i + 1, newNo: nil)); removed += 1; i += 1 }
            while j < m { ops.append(Line(kind: .added, text: midB[j], oldNo: nil, newNo: head + j + 1)); added += 1; j += 1 }
        }

        // Re-attach only `context` lines of the trimmed head and tail.
        var out: [Line] = []
        let headStart = max(0, head - context)
        if headStart > 0 { out.append(Line(kind: .gap, text: "", oldNo: nil, newNo: nil)) }
        for k in headStart..<head {
            out.append(Line(kind: .context, text: a[k], oldNo: k + 1, newNo: k + 1))
        }
        out.append(contentsOf: ops)
        let tailStart = b.count - tail
        let tailEnd = min(b.count, tailStart + context)
        for k in tailStart..<tailEnd {
            out.append(Line(kind: .context, text: b[k], oldNo: nil, newNo: k + 1))
        }
        if tailEnd < b.count { out.append(Line(kind: .gap, text: "", oldNo: nil, newNo: nil)) }

        return (out, Summary(added: added, removed: removed))
    }
}
