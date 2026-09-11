import Foundation

/// Knowing what is running — across a Crook restart, and without mistaking a
/// stranger's process for a session.
///
/// Stand-in runners play Terminal's part: a tiny zsh script in the session
/// folder that reports its PID, maybe starts a child, and exits. The registry
/// cannot tell them from the real one, which is the point.
enum ClaudeRegistryTests {

    private static let fm = FileManager.default

    private static func spin(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    @discardableResult
    private static func startRunner(_ s: ClaudeSession, _ body: String) -> Process {
        let url = s.file("launch.command")
        try? ("#!/bin/zsh\ncd -- \"${0:A:h}\"\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return p
    }

    private static func begin(_ r: SessionRegistry, _ path: String, baseline: Data = Data()) -> ClaudeSession? {
        try? r.begin(filePath: path, providerID: "local", machineName: nil,
                     workingDirectory: (path as NSString).deletingLastPathComponent, baseline: baseline)
    }

    static func run() {
        T.suite("claude-registry — a session's life")
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-sessions-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let registry = SessionRegistry(root: root)
        var seen: [ClaudeSession.State] = []
        registry.onChange = { seen.append($0.state) }
        registry.fileChanged = { _ in false }

        guard let s = begin(registry, "/Users/alice/.claude/CLAUDE.md", baseline: Data("# hi\r\n".utf8)) else {
            T.ok("CG-01  a session begins", false); return
        }
        T.ok("CG-01  a session begins with its exact baseline and its record on disk",
             s.baseline == Data("# hi\r\n".utf8) && fm.fileExists(atPath: s.file("session.json").path))
        T.eq("CG-02  its folder is private",
             (try? fm.attributesOfItem(atPath: s.folder.path))?[.posixPermissions] as? Int, 0o700)
        T.ok("CG-03  it is found by file and machine",
             registry.session(for: "/Users/alice/.claude/CLAUDE.md", providerID: "local") === s)
        T.ok("CG-04  and not by the same path on another machine",
             registry.session(for: "/Users/alice/.claude/CLAUDE.md", providerID: "ssh:mini") == nil)

        registry.watch(s)
        startRunner(s, "print -r -- $$ > runner.pid\nsleep 0.6\nprint -r -- '0 1' > exit\n")
        T.ok("CG-05  the runner reporting in makes it running", spin(5) { s.state == .running })
        T.ok("CG-06  and its exit makes it finished", spin(5) { s.state == .ended(.finished) }, "\(s.state)")
        T.ok("CG-07  both changes were announced", seen.contains(.running) && seen.last == .ended(.finished))

        T.suite("claude-registry — ending one")
        guard let e = begin(registry, "/tmp/e.md") else { return }
        registry.watch(e)
        startRunner(e, """
        print -r -- $$ > runner.pid
        /bin/zsh -fc 'print -r -- $$ > child.pid; exec sleep 30'
        print -r -- "$? 0" > exit
        """)
        _ = spin(5) { e.state == .running && fm.fileExists(atPath: e.file("child.pid").path) }
        let asked = Date()
        registry.requestEnd(e)
        T.ok("CG-08  End Session stops it promptly, and it counts as finished",
             spin(6) { e.state == .ended(.finished) } && Date().timeIntervalSince(asked) < 5, "\(e.state)")
        T.ok("CG-09  the runner was told, so it can close its window", fm.fileExists(atPath: e.file("end-requested").path))

        guard let stubborn = begin(registry, "/tmp/stubborn.md") else { return }
        registry.watch(stubborn)
        startRunner(stubborn, """
        print -r -- $$ > runner.pid
        /bin/zsh -fc 'print -r -- $$ > child.pid; trap "" TERM; while true; do sleep 1; done'
        print -r -- "$? 0" > exit
        """)
        _ = spin(5) { stubborn.state == .running && fm.fileExists(atPath: stubborn.file("child.pid").path) }
        registry.requestEnd(stubborn)
        T.ok("CG-10  a program that ignores SIGTERM is killed three seconds later",
             spin(8) { stubborn.state == .ended(.finished) }, "\(stubborn.state)")

        guard let never = begin(registry, "/tmp/never.md") else { return }
        registry.watch(never, startTimeout: 0.5)
        T.ok("CG-11  no report from the runner in time is didNotStart", spin(3) { never.state == .ended(.didNotStart) })
        T.ok("CG-12  and a runner that turns up late is told to stand down",
             fm.fileExists(atPath: never.file("abandoned").path))

        let parentProbe = Process()
        parentProbe.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parentProbe.arguments = ["5"]
        try? parentProbe.run()
        T.eq("CG-20  a process's parent is read from the kernel, so a kill can check it is still ours",
             SessionRegistry.parentPID(of: parentProbe.processIdentifier), getpid())
        parentProbe.terminate()

        guard let lingering = begin(registry, "/tmp/lingering.md") else { return }
        registry.discard(lingering, deletingFolderAfter: 0.5)
        T.ok("CG-21  a discarded session leaves the list at once, but its folder can outlive it briefly",
             registry.session(for: "/tmp/lingering.md", providerID: "local") == nil
             && fm.fileExists(atPath: lingering.folder.path))
        T.ok("CG-22  so a runner closing its window can still read its script, then it is gone",
             spin(3) { !fm.fileExists(atPath: lingering.folder.path) })

        registry.discard(s)
        T.ok("CG-13  Done forgets a session, folder and all",
             !fm.fileExists(atPath: s.folder.path)
             && registry.session(for: "/Users/alice/.claude/CLAUDE.md", providerID: "local") == nil)

        T.suite("claude-registry — after Crook restarts")
        guard let live = begin(registry, "/tmp/live.md"),
              let ended = begin(registry, "/tmp/ended.md"),
              let old = begin(registry, "/tmp/old.md"),
              let imposter = begin(registry, "/tmp/imposter.md") else { return }
        registry.watch(live)
        let liveRunner = startRunner(live, "print -r -- $$ > runner.pid\nsleep 20\nprint -r -- '0 20' > exit\n")
        _ = spin(5) { live.state == .running }
        ended.record.outcome = .finished
        ended.record.endedAt = Date()
        registry.save(ended)
        old.record.outcome = .finished
        old.record.endedAt = Date().addingTimeInterval(-8 * 86_400)
        registry.save(old)
        imposter.record.runnerPID = getpid()   // alive, but nobody's runner
        registry.save(imposter)
        let stray = root.appendingPathComponent("update-1234", isDirectory: true)
        try? fm.createDirectory(at: stray, withIntermediateDirectories: true)

        let again = SessionRegistry(root: root)
        again.fileChanged = { _ in false }
        again.reattach()
        let back = again.session(for: "/tmp/live.md", providerID: "local")
        T.ok("CG-14  a session still running is running again", back?.state == .running, "\(String(describing: back?.state))")
        T.ok("CG-15  one that ended and was never dismissed still waits for Done",
             again.session(for: "/tmp/ended.md", providerID: "local")?.state == .ended(.finished))
        T.ok("CG-16  one that ended over a week ago is gone",
             again.session(for: "/tmp/old.md", providerID: "local") == nil && !fm.fileExists(atPath: old.folder.path))
        let imp = again.session(for: "/tmp/imposter.md", providerID: "local")
        T.ok("CG-17  a live process that is not this session's runner is not mistaken for it",
             imp != nil && imp?.isLive == false, "\(String(describing: imp?.state))")
        T.ok("CG-18  a folder that is not a session is cleared away", !fm.fileExists(atPath: stray.path))
        liveRunner.terminate()
        T.ok("CG-19  the reattached session still notices its runner exit", spin(5) { back?.isLive == false })
    }
}
