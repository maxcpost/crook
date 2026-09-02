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

        // --- machine isolation -------------------------------------------
        //
        // Nearly shipped the inverse of this. When entry keys gained a machine
        // prefix, prune was still handing whole KEYS to fileExists — so every
        // path looked missing and prune would have deleted the entire store on
        // its first run three seconds after launch.
        T.suite("seen — one store, two machines")

        let dir2 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-two-machines-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir2) }
        let g = dir2.appendingPathComponent("CLAUDE.md")
        try! "one\ntwo\nthree\n".write(to: g, atomically: true, encoding: .utf8)

        let far = StubProvider(id: "ssh:elsewhere")
        Providers.use(far)
        s.markSeen(g)
        Thread.sleep(forTimeInterval: 0.05)
        T.ok("P-04  a file opened on another machine is recorded", s.snapshot(for: g) != nil)

        Providers.useLocal()
        T.ok("P-05  and is invisible from this one", s.snapshot(for: g) == nil)

        // The file is gone from the shared disk, so THIS machine would judge it
        // dead. The other machine's record must survive anyway: not being able
        // to check is not the same as knowing it is gone.
        try? FileManager.default.removeItem(at: g)
        s.prune()
        Providers.use(far)
        T.ok("P-06  pruning here does not touch another machine's records",
             s.snapshot(for: g) != nil)

        // Pruning while actually connected to that machine does clear it.
        s.prune()
        T.ok("P-07  pruning there does", s.snapshot(for: g) == nil)
        Providers.useLocal()
    }
}
