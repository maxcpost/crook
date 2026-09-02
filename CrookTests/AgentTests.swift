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

        // --- watching, from the side that can see it ---
        _ = pipe.send(["op": "watch", "roots": [dir.path]])
        T.ok("A-14  the watch arms", pipe.waitForEvent("watching") != nil)
        usleep(400_000)
        try? "changed by something else\n".write(toFile: real, atomically: false, encoding: .utf8)
        T.ok("A-15  and reports a change made by another process",
             pipe.waitForEvent("changed", timeout: 6) != nil)
    }
}
