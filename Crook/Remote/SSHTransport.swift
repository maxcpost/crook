import Foundation

/// Talks to the agent on another Mac.
///
/// Crook implements no SSH. It runs the system `ssh`, which already knows the
/// user's config, keys, agent and known_hosts — so a machine that works in a
/// terminal works here, and a `Host mac-mini` alias means the whole connect
/// form is one word. Nothing about this is Tailscale-specific: a tailnet is
/// simply what makes the name resolve and carries the bytes.
final class SSHTransport {

    enum Failure: Error, LocalizedError {
        case unreachable(String)
        case authRequired
        case authFailed(String)
        case installFailed(String)
        case dropped
        case timedOut(String)
        case badReply(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let d):    return d
            case .authRequired:          return "That machine needs a passphrase."
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
    private func run(_ args: [String], input: Data? = nil, passphrase: String?,
                     timeout: TimeInterval = 25) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = commonOptions + args
        var env = ProcessInfo.processInfo.environment
        var fifo: AskpassFIFO?
        if let passphrase {
            fifo = AskpassFIFO(passphrase: passphrase)
            if let f = fifo {
                env["SSH_ASKPASS"] = f.helperPath
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["CROOK_ASKPASS_FIFO"] = f.fifoPath
                env["DISPLAY"] = env["DISPLAY"] ?? ":0"   // older ssh still gates on this
            }
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
    func connect(passphrase: String?) throws {
        let probe = run([host, "\(remotePath) --version 2>/dev/null || echo MISSING"],
                        passphrase: passphrase)

        if probe.status != 0 {
            let e = probe.err.lowercased()
            if e.contains("permission denied") || e.contains("no such identity") || e.contains("authentication") {
                throw Failure.authFailed(Self.explain(probe.err, host: host))
            }
            if e.contains("passphrase") || (passphrase == nil && e.contains("batchmode")) {
                throw Failure.authRequired
            }
            if e.contains("could not resolve") || e.contains("name or service") {
                throw Failure.unreachable(
                    "Can't find \(host). Check the name, or that Tailscale is connected on both Macs.")
            }
            // The first-run failure, by a wide margin. ssh reached the network
            // and found nothing listening on 22, which on a Mac means Remote
            // Login is off — not that the machine is unreachable. Saying
            // "connection refused" sends people to look at the network, which
            // is the one thing that is working.
            if e.contains("connection refused") || e.contains("operation timed out")
                || e.contains("no route") || e.contains("connection timed out") {
                throw Failure.unreachable(
                    "\(host) is not accepting SSH. On that Mac, turn on System Settings ▸ "
                    + "General ▸ Sharing ▸ Remote Login.")
            }
            if probe.status == 124 { throw Failure.timedOut("Connecting to \(host)") }
            throw Failure.unreachable(Self.explain(probe.err, host: host))
        }

        let reply = String(data: probe.out, encoding: .utf8) ?? ""
        if reply.contains("MISSING") || !reply.contains("crook-agent \(Self.agentVersion)") {
            try install(passphrase: passphrase)
        }
        try startSession(passphrase: passphrase)
    }

    /// Push the helper. Written to a temp name and moved into place, so a
    /// connection that drops mid-copy cannot leave a half-written executable
    /// that would then be run.
    private func install(passphrase: String?) throws {
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

        let r = run([host, script], input: bin, passphrase: passphrase, timeout: 60)
        guard r.status == 0, String(data: r.out, encoding: .utf8)?.contains("INSTALLED") == true else {
            throw Failure.installFailed(r.err.isEmpty ? "exit \(r.status)" : r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func startSession(passphrase: String?) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = commonOptions + [host, remotePath]
        var env = ProcessInfo.processInfo.environment
        var fifo: AskpassFIFO?
        if let passphrase {
            fifo = AskpassFIFO(passphrase: passphrase)
            if let f = fifo {
                env["SSH_ASKPASS"] = f.helperPath
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["CROOK_ASKPASS_FIFO"] = f.fifoPath
                env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            }
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

/// Feeds a passphrase to ssh without it ever touching the disk.
///
/// ssh with no controlling terminal asks its SSH_ASKPASS program for the
/// passphrase. That program has to be a real executable, so Crook writes a
/// two-line shell script — but the secret itself goes through a FIFO, which
/// means it exists only in the pipe between two processes and there is nothing
/// to shred afterwards. A temp file would have been simpler and would have left
/// the passphrase readable on disk for as long as ssh took to start.
final class AskpassFIFO {
    let helperPath: String
    let fifoPath: String
    private let passphrase: String

    init?(passphrase: String) {
        self.passphrase = passphrase
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

    /// Opening a FIFO for writing blocks until a reader arrives, so this has to
    /// happen off the calling thread — ssh only opens its end when it decides
    /// it actually needs the passphrase, which may be never.
    func serve() {
        let path = fifoPath, secret = passphrase
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = open(path, O_WRONLY)
            guard fd >= 0 else { return }
            let line = secret + "\n"
            _ = line.withCString { write(fd, $0, strlen($0)) }
            close(fd)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: fifoPath)
        try? FileManager.default.removeItem(atPath: helperPath)
    }
}
