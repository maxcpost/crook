import Foundation

/// Talks to the agent on another Mac.
///
/// Crook implements no SSH. It runs the system `ssh`, which already knows the
/// user's config, keys, agent and known_hosts — so a machine that works in a
/// terminal works here, and a `Host mac-mini` alias means the whole connect
/// form is one word. Nothing about this is Tailscale-specific: a tailnet is
/// simply what makes the name resolve and carries the bytes.
final class SSHTransport {

    /// Which secret ssh is missing.
    ///
    /// The two are different things asked of different people: a passphrase
    /// unlocks a key that is already installed, a password is the login on the
    /// far Mac. Labelling one as the other sends someone hunting for a key
    /// they never made — which is most people, since enabling Remote Login
    /// gets you password auth and nothing else.
    enum Secret {
        case keyPassphrase
        case accountPassword

        var prompt: String {
            switch self {
            case .keyPassphrase:   return "Passphrase for your SSH key"
            case .accountPassword: return "Password for your account on that Mac"
            }
        }
    }

    enum Failure: Error, LocalizedError {
        case unreachable(String)
        case authRequired(Secret)
        case authFailed(String)
        case installFailed(String)
        case dropped
        case timedOut(String)
        case badReply(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let d):    return d
            case .authRequired(let s):   return s.prompt
            case .authFailed(let d):     return d
            case .installFailed(let d):  return "Couldn't install Crook's helper: \(d)"
            case .dropped:               return "The connection closed."
            case .timedOut(let op):      return "\(op) timed out."
            case .badReply(let d):       return "Unexpected reply: \(d)"
            }
        }
    }

    let host: String
    private var proc: Process?
    private var toAgent: FileHandle?
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private let lock = NSLock()
    private var nextID = 0
    private var buffer = Data()

    /// Handshake facts, valid once connected.
    private(set) var remoteHome = ""
    private(set) var remoteHostName = ""
    private(set) var isRunning = false

    var onEvent: (([String: Any]) -> Void)?
    var onClosed: (() -> Void)?

    init(host: String) { self.host = host }

    // MARK: - ssh invocation

    /// Shared with anything else already talking to this host.
    ///
    /// ControlMaster means a second connection to a host is a new channel on
    /// the existing one rather than a fresh TCP handshake and a fresh
    /// authentication. If Herdr is holding a session open to the same machine
    /// through /usr/bin/ssh, Crook joins it and connects with no auth at all;
    /// if not, Crook's own master persists and only the first connect pays.
    private var commonOptions: [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(Self.controlPath)",
            "-o", "ControlPersist=10m",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
    }

    /// Caches, not Application Support, and the reason is not tidiness.
    ///
    /// ssh parses -o values with a whitespace-splitting config parser, so a
    /// path containing "Application Support" fails with "keyword controlpath
    /// extra arguments at end of line" — the connection then dies for a reason
    /// that has nothing to do with the network. Caches has no space in it.
    ///
    /// The socket also has to fit sockaddr_un's 104 bytes. %C is a hash of the
    /// connection parameters, which keeps this bounded no matter how long the
    /// hostname is; a readable path would not.
    private static let controlPath: String = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("%C").path
    }()

    /// One-shot command. Used for probing and installing, never for the session.
    private func run(_ args: [String], input: Data? = nil, secret: String?,
                     timeout: TimeInterval = 25) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = commonOptions + args
        var env = ProcessInfo.processInfo.environment
        var fifo: AskpassFIFO?
        if let secret {
            fifo = AskpassFIFO(secret: secret)
            if let f = fifo {
                env["SSH_ASKPASS"] = f.helperPath
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["CROOK_ASKPASS_FIFO"] = f.fifoPath
                env["DISPLAY"] = env["DISPLAY"] ?? ":0"   // older ssh still gates on this
            }
            // We hold exactly one answer. Left to itself ssh would offer it
            // three times and report the same rejection three times slower.
            p.arguments = commonOptions + ["-o", "NumberOfPasswordPrompts=1"] + args
        } else {
            // Never let ssh block on a prompt Crook cannot see.
            env["SSH_ASKPASS_REQUIRE"] = "never"
            p.arguments = commonOptions + ["-o", "BatchMode=yes"] + args
        }
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = inPipe
        do { try p.run() } catch { return (127, Data(), "\(error)") }
        fifo?.serve()

        if let input { inPipe.fileHandleForWriting.write(input) }
        try? inPipe.fileHandleForWriting.close()

        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }

        if g.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            fifo?.cleanup()
            return (124, outData, "timed out")
        }
        p.waitUntilExit()
        fifo?.cleanup()
        return (p.terminationStatus, outData, String(data: errData, encoding: .utf8) ?? "")
    }

    // MARK: - connect

    private static let agentVersion = 1
    private var remotePath: String { "~/.crook/agent-\(Self.agentVersion)" }

    /// Probe, install if needed, then start the session.
    ///
    /// Ordered so the common case is one round trip: an up-to-date helper
    /// answers `--version` and the session starts immediately. Installing only
    /// happens on a first connect or after a Crook upgrade.
    func connect(secret: String?) throws {
        let probe = run([host, "\(remotePath) --version 2>/dev/null || echo MISSING"],
                        secret: secret)

        if probe.status != 0 {
            let e = probe.err.lowercased()
            // Which secret, asked before "gave up".
            //
            // The old order called every "Permission denied" a hard failure.
            // That is wrong twice: under BatchMode ssh never prompts, so that
            // one line is equally what a Mac says when it would happily have
            // taken a password, and what it says when it skipped a key it
            // could not decrypt. Both are recoverable by asking. Only the
            // second attempt — made WITH a secret — is a real refusal.
            if secret == nil, let want = Self.secretWanted(e) {
                throw Failure.authRequired(want)
            }
            if e.contains("permission denied") || e.contains("no such identity") || e.contains("authentication") {
                throw Failure.authFailed(Self.explain(probe.err, host: host))
            }
            if e.contains("could not resolve") || e.contains("name or service") {
                throw Failure.unreachable(
                    "Can't find \(host). Check the name, or that Tailscale is connected on both Macs.")
            }
            // Refused and timed out are different machines' problems, and
            // conflating them sends people to the wrong Mac.
            //
            // Refused is an RST: something answered, so the host is reachable
            // and nothing is listening on 22. On a Mac that is Remote Login,
            // off. Say so plainly — it is the first-run failure by a wide
            // margin.
            if e.contains("connection refused") {
                throw Failure.unreachable(
                    "\(host) refused the connection. On that Mac, turn on System Settings ▸ "
                    + "General ▸ Sharing ▸ Remote Login.")
            }
            // Timed out is silence, and silence has more than one author. It
            // is Remote Login off behind a firewall that drops rather than
            // refuses — but it is equally a VPN on THIS Mac holding a route to
            // the far address, which is not a thing you fix by walking over to
            // the other machine. Name both; claiming to know which would be
            // guessing.
            if e.contains("operation timed out") || e.contains("connection timed out")
                || e.contains("no route") {
                throw Failure.unreachable(
                    "\(host) did not answer. Check Remote Login is on over there — and that a "
                    + "VPN on this Mac is not capturing the route to it.")
            }
            if probe.status == 124 { throw Failure.timedOut("Connecting to \(host)") }
            throw Failure.unreachable(Self.explain(probe.err, host: host))
        }

        let reply = String(data: probe.out, encoding: .utf8) ?? ""
        if reply.contains("MISSING") || !reply.contains("crook-agent \(Self.agentVersion)") {
            try install(secret: secret)
        }
        try startSession(secret: secret)
    }

    /// Push the helper. Written to a temp name and moved into place, so a
    /// connection that drops mid-copy cannot leave a half-written executable
    /// that would then be run.
    private func install(secret: String?) throws {
        guard let src = Bundle.main.url(forResource: "crook-agent", withExtension: nil),
              let bin = FileManager.default.contents(atPath: src.path) else {
            throw Failure.installFailed("Crook's copy of the helper is missing from its own bundle.")
        }
        // The script IS the remote command, and the binary arrives on stdin for
        // its `cat` to consume. Running `sh -s` with the binary as stdin would
        // instead hand a Mach-O to the shell as a script, which fails in a
        // confusing way — the helper appears to install and is nonsense.
        let script = [
            "set -e",
            "mkdir -p ~/.crook",
            "cat > \(remotePath).tmp",
            "chmod 700 \(remotePath).tmp",
            "mv \(remotePath).tmp \(remotePath)",
            "find ~/.crook -maxdepth 1 -name 'agent-*' ! -name 'agent-\(Self.agentVersion)' -delete 2>/dev/null || true",
            "echo INSTALLED",
        ].joined(separator: "; ")

        let r = run([host, script], input: bin, secret: secret, timeout: 60)
        guard r.status == 0, String(data: r.out, encoding: .utf8)?.contains("INSTALLED") == true else {
            throw Failure.installFailed(r.err.isEmpty ? "exit \(r.status)" : r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func startSession(secret: String?) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = commonOptions + [host, remotePath]
        var env = ProcessInfo.processInfo.environment
        var fifo: AskpassFIFO?
        if let secret {
            fifo = AskpassFIFO(secret: secret)
            if let f = fifo {
                env["SSH_ASKPASS"] = f.helperPath
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["CROOK_ASKPASS_FIFO"] = f.fifoPath
                env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            }
            p.arguments = commonOptions + ["-o", "NumberOfPasswordPrompts=1", host, remotePath]
        } else {
            env["SSH_ASKPASS_REQUIRE"] = "never"
        }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch { throw Failure.unreachable("Couldn't start ssh: \(error)") }
        fifo?.serve()
        proc = p
        toAgent = inPipe.fileHandleForWriting

        let ready = DispatchSemaphore(value: 0)
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty {
                self.handleClose()
                return
            }
            self.buffer.append(chunk)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<nl]
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if let id = obj["id"] as? Int {
                    self.lock.lock(); let k = self.pending.removeValue(forKey: id); self.lock.unlock()
                    k?(.success(obj))
                } else {
                    if obj["ev"] as? String == "hello" {
                        self.remoteHome = obj["home"] as? String ?? ""
                        self.remoteHostName = obj["host"] as? String ?? self.host
                        self.isRunning = true
                        ready.signal()
                    }
                    self.onEvent?(obj)
                }
            }
        }
        p.terminationHandler = { [weak self] _ in self?.handleClose() }

        if ready.wait(timeout: .now() + 20) == .timedOut {
            p.terminate(); fifo?.cleanup()
            throw Failure.timedOut("Starting Crook's helper on \(host)")
        }
        fifo?.cleanup()
    }

    private func handleClose() {
        guard isRunning || proc != nil else { return }
        isRunning = false
        lock.lock()
        let waiters = pending.values
        pending.removeAll()
        lock.unlock()
        for w in waiters { w(.failure(Failure.dropped)) }
        proc = nil
        toAgent = nil
        DispatchQueue.main.async { [weak self] in self?.onClosed?() }
    }

    func disconnect() {
        if isRunning { _ = try? send(["op": "bye"], timeout: 1) }
        proc?.terminate()
        handleClose()
    }

    // MARK: - request / reply

    @discardableResult
    func send(_ body: [String: Any], timeout: TimeInterval = 20) throws -> [String: Any] {
        guard isRunning, let toAgent else { throw Failure.dropped }
        lock.lock(); nextID += 1; let id = nextID; lock.unlock()
        var msg = body; msg["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else {
            throw Failure.badReply("could not encode \(body["op"] ?? "?")")
        }
        data.append(0x0A)

        let sem = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(Failure.dropped)
        lock.lock(); pending[id] = { r in result = r; sem.signal() }; lock.unlock()

        do { try toAgent.write(contentsOf: data) }
        catch { lock.lock(); pending[id] = nil; lock.unlock(); throw Failure.dropped }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending[id] = nil; lock.unlock()
            throw Failure.timedOut(String(describing: body["op"] ?? "request"))
        }
        return try result.get()
    }

    /// Which secret, if any, would make this attempt succeed.
    ///
    /// ssh names the methods it was willing to try in the parentheses of its
    /// refusal — `Permission denied (publickey,password,keyboard-interactive)`
    /// — and that list is the entire answer. Password or keyboard-interactive
    /// on the list means a password is worth asking for. Only publickey means
    /// the one secret that could still help is the passphrase on a key ssh
    /// skipped because it could not decrypt it. Neither means nothing typed
    /// into a box will change the outcome, and offering a field would be a
    /// lie.
    static func secretWanted(_ lowercasedStderr: String) -> Secret? {
        let e = lowercasedStderr
        if e.contains("passphrase") { return .keyPassphrase }
        guard e.contains("permission denied") || e.contains("authentications that can continue")
        else { return nil }
        if e.contains("password") || e.contains("keyboard-interactive") { return .accountPassword }
        if e.contains("publickey") { return .keyPassphrase }
        return nil
    }

    /// Turn ssh's stderr into something worth reading.
    private static func explain(_ raw: String, host: String) -> String {
        let line = raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") } ?? ""
        if line.isEmpty { return "\(host) did not answer." }
        return line
    }
}

// MARK: - askpass

/// Feeds a secret to ssh without it ever touching the disk.
///
/// ssh with no controlling terminal asks its SSH_ASKPASS program for whatever
/// it needs — a key passphrase or an account password, the mechanism is the
/// same. That program has to be a real executable, so Crook writes a two-line
/// shell script, but the secret itself goes through a FIFO: it exists only in
/// the pipe between two processes and there is nothing to shred afterwards. A
/// temp file would have been simpler and would have left the secret readable
/// on disk for as long as ssh took to start.
final class AskpassFIFO {
    let helperPath: String
    let fifoPath: String
    private let secret: String
    private let lock = NSLock()
    private var finished = false

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    init?(secret: String) {
        self.secret = secret
        // Writing into a FIFO whose reader has gone raises SIGPIPE, and the
        // default disposition for that is to kill the process. Crook must not
        // die because ssh gave up on a prompt a moment early.
        Self.ignoreSIGPIPE
        let dir = Paths.support.appendingPathComponent("askpass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let tag = UUID().uuidString
        fifoPath = dir.appendingPathComponent("f-\(tag)").path
        helperPath = dir.appendingPathComponent("ask-\(tag).sh").path
        guard mkfifo(fifoPath, 0o600) == 0 else { return nil }
        let script = "#!/bin/sh\nexec cat \"$CROOK_ASKPASS_FIFO\"\n"
        guard (try? script.write(toFile: helperPath, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperPath)
    }

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Opening a FIFO for writing blocks until a reader arrives, so this has to
    /// happen off the calling thread — ssh only opens its end when it decides
    /// it actually needs the secret, which may be never.
    ///
    /// It answers repeatedly rather than once. ssh runs the askpass program
    /// afresh for every prompt, and a session can hold more than one: a key
    /// passphrase and then a password, or the same question again after a
    /// rejection. A writer that answered once left the next `cat` reading a
    /// closed pipe and returning nothing, which ssh reports as a wrong
    /// password — the confusing failure where the right secret is refused.
    func serve() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Bounded, because ssh is bounded: NumberOfPasswordPrompts caps
            // the far side, and an unbounded loop here would outlive the
            // process it was serving.
            for _ in 0..<4 {
                guard let self, !self.isFinished else { return }
                let fd = open(self.fifoPath, O_WRONLY)
                guard fd >= 0 else { return }
                // cleanup() opens the read end to release this open(); that is
                // a wake-up, not a question, and must not be answered.
                if self.isFinished { close(fd); return }
                let line = self.secret + "\n"
                _ = line.withCString { write(fd, $0, strlen($0)) }
                close(fd)
            }
        }
    }

    /// Unlinking alone would strand the writer: a thread parked in
    /// open(O_WRONLY) stays parked until a reader arrives, and removing the
    /// path does not summon one. Opening the read end for an instant lets that
    /// open() return so the thread can see it is done and leave.
    func cleanup() {
        lock.lock(); finished = true; lock.unlock()
        let fd = open(fifoPath, O_RDONLY | O_NONBLOCK)
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(atPath: fifoPath)
        try? FileManager.default.removeItem(atPath: helperPath)
    }
}
