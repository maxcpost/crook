import Foundation

enum DiffTests {
    static func run() {
        T.suite("diff — which lines an external write touched")

        func d(_ a: String, _ b: String) -> LineDiff.Result? { LineDiff.between(a, b) }

        T.ok("D-01  an identical write reports nothing", d("a\nb\nc", "a\nb\nc") == nil)

        if let r = d("a\nb\nc\n", "a\nb\nX\nY\nc\n") {
            T.eq("D-02  an insertion starts at the first new line", r.firstChanged, 3)
            T.eq("D-03  and ends at the last", r.lastChanged, 4)
            T.eq("D-04  delta counts the lines added", r.delta, 2)
        } else { T.ok("D-02..04 insertion detected", false) }

        if let r = d("a\nb\nc\nd\n", "a\nd\n") {
            T.eq("D-05  a deletion has last < first", r.lastChanged < r.firstChanged, true)
            T.eq("D-06  and a negative delta", r.delta, -2)
        } else { T.ok("D-05..06 deletion detected", false) }

        if let r = d("a\nb\nc\n", "a\nZ\nc\n") {
            T.eq("D-07  a single-line replacement is one line", r.firstChanged, 2)
            T.eq("D-08  not a range", r.lastChanged, 2)
            T.eq("D-09  with no net change", r.delta, 0)
        } else { T.ok("D-07..09 replacement detected", false) }

        // The common shape: an agent rewrites a contiguous middle section.
        let before = "# T\n\nintro\n\n## A\n- one\n- two\n\n## B\ntail\n"
        let after  = "# T\n\nintro\n\n## A\n- one\n- two\n- three\n- four\n\n## B\ntail\n"
        if let r = d(before, after) {
            T.eq("D-10  a contiguous rewrite is exact, not over-broad", r.firstChanged, 8)
            T.eq("D-11  bounded to what moved", r.lastChanged, 9)
        } else { T.ok("D-10..11 contiguous rewrite", false) }

        // Over-broad is the SAFE direction: a scattered edit highlights more
        // than moved, never less. This asserts the direction, not the extent.
        if let r = d("a\nb\nc\nd\ne\n", "a\nX\nc\nY\ne\n") {
            T.ok("D-12  a scattered edit over-covers rather than under-covers",
                 r.firstChanged <= 2 && r.lastChanged >= 4)
        } else { T.ok("D-12 scattered edit", false) }
    }
}

extension DiffTests {
    /// The change view is a viewer. These assert what it SHOWS, and that it
    /// stays a viewer.
    static func unified() {
        T.suite("diff — the change view")

        let old = "# T\n\n- one\n- two\n\n## N\nold note\n"
        let new = "# T\n\n- one\n- two\n- three\n\n## N\nnew note\n"
        let (lines, s) = UnifiedDiff.between(old, new)

        T.eq("U-01  counts what was added", s.added, 2)
        T.eq("U-02  counts what was removed", s.removed, 1)
        T.ok("U-03  the added line is present",
             lines.contains { $0.kind == .added && $0.text == "- three" })
        T.ok("U-04  the removed line is present",
             lines.contains { $0.kind == .removed && $0.text == "old note" })
        T.ok("U-05  unchanged lines come through as context",
             lines.contains { $0.kind == .context && $0.text == "- one" })

        let (same, s2) = UnifiedDiff.between(old, old)
        T.ok("U-06  an identical file reports no change", s2.isEmpty)
        T.ok("U-07  and produces no add/remove rows",
             !same.contains { $0.kind == .added || $0.kind == .removed })

        // A whole-file replacement must not hang: the LCS is capped and falls
        // back to a block replace.
        let bigA = (0..<900).map { "alpha \($0)" }.joined(separator: "\n")
        let bigB = (0..<900).map { "beta \($0)" }.joined(separator: "\n")
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (_, s3) = UnifiedDiff.between(bigA, bigB)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        T.ok("U-08  a 900-line whole-file rewrite completes in under 250 ms",
             ms < 250, String(format: "%.0f ms", ms))
        T.eq("U-09  and reports every line on both sides", s3.added, 900)
    }
}
