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

    /// `lcsCellLimit` is how large a middle the full comparison takes on;
    /// past it, the edit-distance path below. Tests lower it to check the two
    /// agree.
    static func between(_ old: String, _ new: String, context: Int = 3,
                        lcsCellLimit: Int = 400_000) -> ([Line], Summary) {
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

        // A middle too large for the full comparison, which is O(n*m): a long
        // file with a few scattered changes, or a whole-file rewrite. The
        // edit-distance path costs time in proportion to how much changed, so
        // the first stays precise; the second, past its limit, is reported as
        // the block replace it effectively is.
        if midA.count * midB.count > lcsCellLimit {
            if let script = editScript(midA, midB, maxChanges: 1000) {
                for step in script {
                    switch step {
                    case .same(let i, let j):
                        ops.append(Line(kind: .context, text: midA[i], oldNo: head + i + 1, newNo: head + j + 1))
                    case .removed(let i):
                        ops.append(Line(kind: .removed, text: midA[i], oldNo: head + i + 1, newNo: nil)); removed += 1
                    case .added(let j):
                        ops.append(Line(kind: .added, text: midB[j], oldNo: nil, newNo: head + j + 1)); added += 1
                    }
                }
            } else {
                for (i, l) in midA.enumerated() {
                    ops.append(Line(kind: .removed, text: l, oldNo: head + i + 1, newNo: nil)); removed += 1
                }
                for (i, l) in midB.enumerated() {
                    ops.append(Line(kind: .added, text: l, oldNo: nil, newNo: head + i + 1)); added += 1
                }
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

    enum Step: Equatable {
        case same(Int, Int)
        case removed(Int)
        case added(Int)
    }

    /// The shortest edit script from `a` to `b` (Myers, 1986), or nil when it
    /// needs more than `maxChanges` added and removed lines.
    ///
    /// Only the diagonals each round can reach are kept, so memory grows with
    /// the square of the changes, not the size of the file.
    static func editScript(_ a: [String], _ b: [String], maxChanges: Int) -> [Step]? {
        // Compare numbers, not strings, in the inner loop.
        var ids: [String: Int32] = [:]
        let x0 = a.map { line -> Int32 in
            if let id = ids[line] { return id }
            let id = Int32(ids.count); ids[line] = id; return id
        }
        let y0 = b.map { line -> Int32 in
            if let id = ids[line] { return id }
            let id = Int32(ids.count); ids[line] = id; return id
        }
        let n = x0.count, m = y0.count
        let limit = min(maxChanges, n + m)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int32]] = []
        var found: Int?

        search: for d in 0...limit {
            // The furthest point on each diagonal before this round.
            trace.append(v[(offset - d)...(offset + d)].map { Int32($0) })
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]))
                    ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, x0[x] == y0[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = d; break search }
            }
        }
        guard let changes = found else { return nil }

        var steps: [Step] = []
        var x = n, y = m
        for d in stride(from: changes, through: 1, by: -1) {
            let before = trace[d]
            func at(_ k: Int) -> Int { Int(before[k + d]) }
            let k = x - y
            let prevK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let prevX = at(prevK)
            let prevY = prevX - prevK
            while x > prevX && y > prevY { x -= 1; y -= 1; steps.append(.same(x, y)) }
            if x == prevX { y -= 1; steps.append(.added(y)) } else { x -= 1; steps.append(.removed(x)) }
        }
        while x > 0 && y > 0 { x -= 1; y -= 1; steps.append(.same(x, y)) }
        return steps.reversed()
    }
}
