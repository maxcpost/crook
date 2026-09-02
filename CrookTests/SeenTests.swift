import Foundation

enum SeenTests {
    static func run() {
        T.suite("seen — the agent's writes as a queue you review")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-seen-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("CLAUDE.md")

        func write(_ n: Int, _ marker: String = "x") {
            let body = (0..<n).map { "line \($0) \(marker)" }.joined(separator: "\n") + "\n"
            try! body.write(to: f, atomically: true, encoding: .utf8)
            Thread.sleep(forTimeInterval: 0.02)
        }
        let s = SeenStore.shared

        write(10)
        T.ok("S-01  a file never opened draws nothing", s.delta(for: f) == nil)

        s.markSeen(f)
        T.ok("S-02  just opened, unchanged, draws nothing", s.delta(for: f) == nil)

        write(17)
        T.eq("S-03  the agent added 7 lines", s.delta(for: f) ?? .min, 7)

        s.markSeen(f)
        T.ok("S-04  opening it clears the figure", s.delta(for: f) == nil)

        write(5)
        T.eq("S-05  the agent removed 12", s.delta(for: f) ?? .min, -12)

        // G9: a zero-net-line rewrite draws ±0 — 13.8% of real markdown
        // rewrites change bytes without changing the line count, and silence
        // there would hide the majority-adjacent case.
        s.markSeen(f)
        write(5, "y")
        T.eq("S-06  a zero-net rewrite draws 0, not nothing", s.delta(for: f) ?? .min, 0)

        s.markSeen(f)
        try! FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        T.ok("S-07  touched but byte-identical draws nothing", s.delta(for: f) == nil)

        try? FileManager.default.removeItem(at: f)
        T.ok("S-08  a deleted file draws nothing", s.delta(for: f) == nil)

        // The glyph itself.
        T.eq("S-09  the minus sign is U+2212, never an ASCII hyphen",
             SeenStore.format(-12), "\u{2212}12")
        T.eq("S-10  a positive delta is signed", SeenStore.format(7), "+7")
        T.eq("S-11  zero is signed too", SeenStore.format(0), "\u{00B1}0")

        // Crook never writes into the corpus it watches. The fixture is the
        // corpus this suite actually touches, so it leads; the machine's own
        // ~/.claude is checked too when it exists, and skipped when it does not.
        var stray = 0
        for root in [T.fixtureRoot.path,
                     "\(NSHomeDirectory())/.claude",
                     "\(NSHomeDirectory())/Documents"] {
            if let e = FileManager.default.enumerator(atPath: root) {
                var n = 0
                for case let p as String in e {
                    n += 1; if n > 20000 { break }
                    if (p as NSString).lastPathComponent.hasPrefix(".crook") { stray += 1 }
                }
            }
        }
        T.eq("S-12  no .crook* file anywhere in the user's tree", stray, 0)
    }
}

extension SeenTests {
    static func pruning() {
        T.suite("seen — retiring state for files that are gone")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crook", isDirectory: true)
        let snaps = base.appendingPathComponent("snapshots", isDirectory: true)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-prune-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("CLAUDE.md")
        try! "# gone soon\n".write(to: f, atomically: true, encoding: .utf8)

        let s = SeenStore.shared
        s.markSeen(f)
        Thread.sleep(forTimeInterval: 0.05)
        T.ok("P-01  opening a file stores its content", s.snapshot(for: f) != nil)
        let countWith = (try? FileManager.default.contentsOfDirectory(atPath: snaps.path).count) ?? 0

        try? FileManager.default.removeItem(at: dir)
        s.prune()
        let countAfter = (try? FileManager.default.contentsOfDirectory(atPath: snaps.path).count) ?? 0
        T.ok("P-02  prune drops the snapshot of a deleted file",
             countAfter < countWith, "\(countWith) -> \(countAfter)")
        T.ok("P-03  and the entry with it", s.delta(for: f) == nil)
    }
}
