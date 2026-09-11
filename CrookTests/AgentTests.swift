import Foundation

/// Drives the real remote agent over a pipe.
///
/// `ssh host crook-agent` is just "run this program with its stdio wired up",
/// so a pipe exercises everything except the network hop — the framing, the
/// protocol, and above all whether bytes survive the trip. That last property
/// is the one Crook cannot afford to get wrong, and it is testable here without
/// a second machine, which is the whole reason this file exists.
enum AgentTests {

    /// Talks to the agent the way SSHTransport does.
    private final class Pipeline {
        let proc = Process()
        private let toAgent = Pipe()
        private let fromAgent = Pipe()
        private var buffer = Data()
        private var pending: [Int: [String: Any]] = [:]
        private var events: [[String: Any]] = []
        private let lock = NSLock()
        private var nextID = 0

        init?(binary: String) {
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.standardInput = toAgent
            proc.standardOutput = fromAgent
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { return nil }
            fromAgent.fileHandleForReading.readabilityHandler = { [weak self] h in
                guard let self else { return }
                let d = h.availableData
                if d.isEmpty { return }
                self.lock.lock()
                self.buffer.append(d)
                while let nl = self.buffer.firstIndex(of: 0x0A) {
                    let line = Data(self.buffer[self.buffer.startIndex..<nl])
                    self.buffer.removeSubrange(self.buffer.startIndex...nl)
                    if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        if let id = o["id"] as? Int { self.pending[id] = o } else { self.events.append(o) }
                    }
                }
                self.lock.unlock()
            }
        }

        func waitForEvent(_ name: String, timeout: TimeInterval = 5) -> [String: Any]? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                let hit = events.first { $0["ev"] as? String == name }
                lock.unlock()
                if let hit { return hit }
                usleep(5_000)
            }
            return nil
        }

        func send(_ body: [String: Any], timeout: TimeInterval = 20) -> [String: Any]? {
            lock.lock(); nextID += 1; let id = nextID; lock.unlock()
            var m = body; m["id"] = id
            guard var d = try? JSONSerialization.data(withJSONObject: m) else { return nil }
            d.append(0x0A)
            toAgent.fileHandleForWriting.write(d)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock(); let r = pending.removeValue(forKey: id); lock.unlock()
                if let r { return r }
                usleep(3_000)
            }
            return nil
        }

        func finish() {
            _ = send(["op": "bye"], timeout: 2)
            proc.terminate()
        }
    }

    static func run() {
        T.suite("agent — the far side of the connection")

        guard let bin = ProcessInfo.processInfo.environment["CROOK_AGENT_BIN"],
              FileManager.default.isExecutableFile(atPath: bin) else {
            T.skip("A-  agent tests", "CROOK_AGENT_BIN not set; run via scripts/test.sh")
            return
        }
        guard let pipe = Pipeline(binary: bin) else {
            T.ok("A-00  agent starts", false, "could not launch \(bin)")
            return
        }
        defer { pipe.finish() }

        // --- handshake ---
        let hello = pipe.waitForEvent("hello")
        T.ok("A-01  announces itself before any request", hello != nil)
        T.eq("A-02  reports the home of the machine it runs on",
             hello?["home"] as? String ?? "", NSHomeDirectory())
        T.ok("A-03  and identifies its own build", (hello?["sha256"] as? String)?.count == 64)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-agent-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // --- the property that matters ---
        //
        // These are the shapes that break editors: a CRLF file, one with no
        // final newline, one carrying a BOM, and one with characters outside
        // the basic plane. If any of them comes back altered, the byte-exact
        // promise does not survive the wire and nothing else matters.
        let awkward: [(String, [UInt8])] = [
            ("crlf.md",        Array("---\r\nname: a\r\n---\r\n\r\n# Hi\r\n".utf8)),
            ("no-newline.md",  Array("# ends abruptly".utf8)),
            ("bom.md",         [0xEF, 0xBB, 0xBF] + Array("# after a BOM\n".utf8)),
            ("astral.md",      Array("# \u{1F411} sheep and \u{1D11E} clef\n".utf8)),
            ("trailing.md",    Array("line with spaces   \nand a tab\t\n".utf8)),
            ("empty.md",       []),
        ]

        var allExact = true
        for (name, bytes) in awkward {
            let path = dir.appendingPathComponent(name).path
            let data = Data(bytes)
            // Write it THROUGH the agent, then read it back THROUGH the agent,
            // so both directions are covered by one comparison.
            let w = pipe.send(["op": "write", "path": path, "b64": data.base64EncodedString()])
            guard w?["ok"] as? Bool == true else {
                T.ok("A-04  \(name) writes", false, "write refused"); allExact = false; continue
            }
            let onDisk = FileManager.default.contents(atPath: path) ?? Data()
            let r = pipe.send(["op": "read", "path": path])
            let back = (r?["b64"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            let exact = onDisk == data && back == data
            if !exact {
                allExact = false
                T.ok("A-04  \(name) survives the round trip", false,
                     "\(data.count) bytes out, \(onDisk.count) on disk, \(back.count) back")
            }
        }
        T.ok("A-04  every awkward encoding survives write-then-read unaltered", allExact)

        // CLAUDE.md -> AGENTS.md on the other Mac, as on this one: the write
        // changes the file the link names and keeps the link.
        let agents = dir.appendingPathComponent("AGENTS.md").path
        let link = dir.appendingPathComponent("CLAUDE.md").path
        try? Data("before\n".utf8).write(to: URL(fileURLWithPath: agents))
        try? FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: agents)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "AGENTS.md")
        let through = pipe.send(["op": "write", "path": link, "b64": Data("after\n".utf8).base64EncodedString()])
        T.ok("A-30  a write through a symlink changes the file it names and keeps the link",
             through?["ok"] as? Bool == true
             && (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == "AGENTS.md"
             && FileManager.default.contents(atPath: agents) == Data("after\n".utf8),
             "\(through ?? [:])")
        T.eq("A-31  and keeps that file's permissions",
             (try? FileManager.default.attributesOfItem(atPath: agents))?[.posixPermissions] as? Int, 0o640)

        // --- the same corpus the byte tests use ---
        let corpus = T.fixtureRoot.appendingPathComponent("corpus")
        var checked = 0, mismatched = 0
        if let e = FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.pathExtension == "md" {
                guard let want = FileManager.default.contents(atPath: f.path) else { continue }
                guard let r = pipe.send(["op": "read", "path": f.path]),
                      let b64 = r["b64"] as? String, let got = Data(base64Encoded: b64) else {
                    mismatched += 1; continue
                }
                checked += 1
                if got != want { mismatched += 1 }
            }
        }
        T.ok("A-05  the whole fixture corpus reads back byte-identical",
             checked > 0 && mismatched == 0, "\(checked) files, \(mismatched) wrong")

        // --- existence, answered on the agent's side ---
        let real = dir.appendingPathComponent("crlf.md").path
        let fake = "/Users/nobody-here/gone/x.md"
        let st = pipe.send(["op": "stat", "paths": [real, fake, dir.path]])
        let rows = st?["stats"] as? [[Any]] ?? []
        T.eq("A-06  batched stat answers every path in one round trip", rows.count, 3)
        T.ok("A-07  a real file is real", rows.first?[1] as? Bool == true)
        T.ok("A-08  a dead path is dead", rows.count > 1 && rows[1][1] as? Bool == false)
        T.ok("A-09  a directory says so", rows.count > 2 && rows[2][2] as? Bool == true)

        // --- the tree ---
        let tree = pipe.send(["op": "tree", "roots": [dir.path]])
        let trows = tree?["rows"] as? [[Any]] ?? []
        T.ok("A-10  the tree arrives in a single reply", trows.count >= awkward.count,
             "\(trows.count) entries")
        // Line counts come from the far side precisely so a changed file does
        // not need a second round trip before its figure can be drawn.
        let crlfRow = trows.first { ($0[0] as? String)?.hasSuffix("crlf.md") == true }
        T.eq("A-11  and carries line counts computed there", crlfRow?[4] as? Int ?? -1, 5)

        // --- refusing what it was not asked to serve ---
        _ = pipe.send(["op": "roots", "paths": [dir.path]])
        let outside = pipe.send(["op": "read", "path": Paths.home + "/.zshrc"])
        T.ok("A-12  a path outside the declared roots is refused",
             outside?["ok"] as? Bool == false)
        let inside = pipe.send(["op": "read", "path": real])
        T.ok("A-13  and one inside them still works", inside?["ok"] as? Bool == true)

        // A project reached through a linked folder, the way Dropbox and Google
        // Drive set theirs up: the path is inside the roots, the file it names
        // is not, and it must still save.
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-agent-linked-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try? Data("old\n".utf8).write(to: elsewhere.appendingPathComponent("CLAUDE.md"))
        try? FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("linked").path,
                                                    withDestinationPath: elsewhere.path)
        let linkedWrite = pipe.send(["op": "write", "path": dir.appendingPathComponent("linked/CLAUDE.md").path,
                                     "b64": Data("new\n".utf8).base64EncodedString()])
        T.ok("A-32  a file in a project reached through a linked folder still saves",
             linkedWrite?["ok"] as? Bool == true
             && FileManager.default.contents(atPath: elsewhere.appendingPathComponent("CLAUDE.md").path) == Data("new\n".utf8),
             "\(linkedWrite ?? [:])")

        // --- watching, from the side that can see it ---
        _ = pipe.send(["op": "watch", "roots": [dir.path]])
        T.ok("A-14  the watch arms", pipe.waitForEvent("watching") != nil)
        usleep(400_000)
        try? "changed by something else\n".write(toFile: real, atomically: false, encoding: .utf8)
        T.ok("A-15  and reports a change made by another process",
             pipe.waitForEvent("changed", timeout: 6) != nil)
    }
}

// MARK: - transport

extension AgentTests {

    /// The failure paths, which are most of what a network state machine is.
    ///
    /// None of these need a reachable machine — that is the point. A connection
    /// attempt that hangs, or that reports "something went wrong", is worse than
    /// one that fails, and those are the two outcomes worth pinning down before
    /// there is a Mac mini to try it against.
    static func transport() {
        T.suite("transport — failing usefully")

        let t = SSHTransport(host: "crook-no-such-host.invalid")
        let began = Date()
        var caught: Error?
        do { try t.connect(secret: nil) } catch { caught = error }
        let took = Date().timeIntervalSince(began)

        T.ok("X-01  an unresolvable host fails rather than hanging", caught != nil)
        T.ok("X-02  and fails promptly", took < 30, String(format: "%.1fs", took))

        let message = caught?.localizedDescription ?? ""
        T.ok("X-03  the message names the machine, not the plumbing",
             message.contains("crook-no-such-host") || message.lowercased().contains("resolve"),
             message)
        T.ok("X-04  and is not an opaque code", !message.isEmpty && !message.contains("Error Domain"),
             message)

        // Sending on a transport that never connected must fail cleanly, not
        // crash and not block: every provider call goes through this path when
        // the link is down.
        var sendFailed = false
        do { _ = try t.send(["op": "ping"], timeout: 2) } catch { sendFailed = true }
        T.ok("X-05  requests on a dead transport fail immediately", sendFailed)
        T.ok("X-06  and it does not claim to be running", !t.isRunning)
    }

    /// Reading ssh's refusal for the one thing that would fix it.
    ///
    /// These are real stderr lines. The distinction they encode is not
    /// cosmetic: a Mac with Remote Login freshly switched on offers password
    /// auth and nothing else, so calling its refusal a hard failure — which is
    /// what shipped — locks out everyone who has not made a key. Getting the
    /// KIND right matters just as much, because a passphrase and a login
    /// password are different things to go and find.
    static func authClassification() {
        T.suite("transport — which secret ssh actually wants")

        typealias S = SSHTransport.Secret
        func want(_ s: String, hasIdentity: Bool = true) -> S? {
            SSHTransport.secretWanted(s.lowercased(), hasIdentity: hasIdentity)
        }

        // The default Mac. Remote Login on, no key installed.
        let fresh = "mac-mini@10.0.0.4: Permission denied (publickey,password,keyboard-interactive)."
        T.ok("A-01  a Mac offering password auth asks for a password",
             want(fresh) == .accountPassword)

        T.ok("A-02  keyboard-interactive alone counts as a password",
             want("Permission denied (keyboard-interactive).") == .accountPassword)

        // Keys only, and the key on disk is encrypted: ssh skips it silently
        // under BatchMode and reports the same one-line refusal.
        T.ok("A-03  a publickey-only refusal asks for the key's passphrase",
             want("Permission denied (publickey).") == .keyPassphrase)

        T.ok("A-04  an explicit passphrase prompt is a passphrase",
             want("Enter passphrase for key '/Users/x/.ssh/id_ed25519':") == .keyPassphrase)

        // Offering a field here would be a lie — no secret reopens a closed
        // port or resolves a name that does not exist.
        T.ok("A-05  an unreachable host wants no secret",
             want("ssh: connect to host mac-mini port 22: Operation timed out") == nil)
        T.ok("A-06  nor does a name that will not resolve",
             want("ssh: Could not resolve hostname mac-mini") == nil)
        T.ok("A-07  nor does a host key mismatch",
             want("Host key verification failed.") == nil)

        // Under BatchMode the publickey-only refusal is one line for "your key
        // is encrypted", "you have no key", and "that key is not authorised".
        // Whether a key file exists is the only local fact that separates
        // them, and with none, a passphrase field is a lie.
        T.ok("A-08  a publickey-only refusal with no key on this Mac wants no secret",
             want("Permission denied (publickey).", hasIdentity: false) == nil)
        T.ok("A-09  but a password offer still wants a password, key or no key",
             want("Permission denied (publickey,password).", hasIdentity: false) == .accountPassword)
    }

    /// The askpass FIFO has to answer more than once.
    ///
    /// ssh runs the askpass program afresh for every prompt. The version that
    /// wrote once left the second `cat` reading a closed pipe and returning
    /// nothing, which ssh reports as a wrong password — the right secret,
    /// refused, with no way to tell why.
    static func askpass() {
        T.suite("transport — answering ssh more than once")

        guard let f = AskpassFIFO(secret: "hunter2") else {
            T.ok("K-01  the FIFO could be created", false)
            return
        }
        f.serve()

        // Exactly what the helper script does, twice.
        func ask() -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/cat")
            p.arguments = [f.fifoPath]
            let out = Pipe()
            p.standardOutput = out
            guard (try? p.run()) != nil else { return "" }
            // A FIFO with no writer blocks in open() forever. If serve() ever
            // stops answering, this test must fail rather than hang the suite.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if p.isRunning { p.terminate() }
            }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: d, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        T.ok("K-01  the first prompt is answered", ask() == "hunter2")
        T.ok("K-02  and so is the second", ask() == "hunter2")

        f.cleanup()
        T.ok("K-03  cleanup removes the pipe",
             !FileManager.default.fileExists(atPath: f.fifoPath))
        T.ok("K-04  and the helper script with it",
             !FileManager.default.fileExists(atPath: f.helperPath))
    }
}

// MARK: - the cost of being far away

extension AgentTests {

    /// Nothing here needs a network. What it checks is that the code paths which
    /// run per keystroke and per rail rebuild ask the filesystem in BATCHES,
    /// because the difference between one round trip and forty is the
    /// difference between usable and not.
    static func latency() {
        T.suite("remote — asking once instead of forty times")

        let stub = StubProvider(id: "ssh:pretend")
        Providers.use(stub)
        defer { Providers.useLocal() }

        let doc = """
        ---
        name: deploy
        description: deploys things
        ---

        # Deploy

        Read /Users/nobody-here/one/a.md and /Users/nobody-here/two/b.md first.
        Then ~/Notes/three/c.md, ~/Notes/four/d.md and /Users/nobody-here/five/e.md.
        Templates live at /Users/nobody-here/six/f.md and /Users/nobody-here/seven/g.md.
        """

        stub.resetCounts()
        _ = PathScanner.scan(doc, url: nil, roleGated: false)

        T.eq("L-01  the scan prefetches exactly once", stub.prefetchCalls, 1)
        T.ok("L-02  and asks about every path in that one call", stub.prefetched.count >= 7,
             "\(stub.prefetched.count) paths")
        T.ok("L-03  tilde paths are expanded against the FAR machine's home",
             stub.prefetched.contains { $0.hasPrefix(stub.homePath + "/Notes") })

        // The real cost check. With latency on every individual question, a
        // scan that batches stays fast and one that does not crawls.
        stub.resetCounts()
        stub.latencyMS = 12
        let began = Date()
        _ = PathScanner.scan(doc, url: nil, roleGated: false)
        let took = Date().timeIntervalSince(began)
        stub.latencyMS = 0
        T.ok("L-04  a document's worth of links stays under a second at 12 ms a hop",
             took < 1.0, String(format: "%.2fs across %d single lookups", took, stub.existsCalls))
    }
}
