import Foundation

/// The real runner scripts, run the way Terminal runs them, against stand-ins
/// for claude and ssh that write down exactly what they were given.
///
/// `ssh host command` is a login shell on the far Mac running a string, so a
/// stub that runs that string through /bin/sh here exercises the whole remote
/// path — the template, the base64, the argument handling — minus the network.
/// Same idea as the agent tests: the full contract, no second Mac.
enum ClaudeRunnerTests {

    private static let fm = FileManager.default

    /// A scratch folder with stub programs in it.
    private final class Bench {
        let dir: URL
        let bin: URL
        let out: URL
        let claude: URL
        let ssh: URL
        let shell: URL
        /// A second copy of the stub, standing in for the claude Crook checked.
        private(set) var verified: URL!

        init() {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("crook-runner-\(UUID().uuidString.prefix(8))", isDirectory: true)
            bin = dir.appendingPathComponent("bin", isDirectory: true)
            out = dir.appendingPathComponent("out", isDirectory: true)
            claude = bin.appendingPathComponent("claude")
            ssh = bin.appendingPathComponent("ssh")
            shell = bin.appendingPathComponent("login-shell")
            try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            install(claude, #"""
            #!/bin/zsh
            print -rn -- "$0" > "$CROOK_STUB_OUT/which"
            print -rn -- "$PATH" > "$CROOK_STUB_OUT/path"
            print -rn -- "$PWD" > "$CROOK_STUB_OUT/cwd"
            : > "$CROOK_STUB_OUT/args"
            for a in "$@"; do print -rn -- "$a" >> "$CROOK_STUB_OUT/args"; printf '\0' >> "$CROOK_STUB_OUT/args"; done
            exit ${CROOK_STUB_EXIT:-0}
            """#)
            install(ssh, #"""
            #!/bin/zsh
            : > "$CROOK_STUB_OUT/ssh-args"
            for a in "$@"; do print -rn -- "$a" >> "$CROOK_STUB_OUT/ssh-args"; printf '\0' >> "$CROOK_STUB_OUT/ssh-args"; done
            exec /bin/sh -c "${@[-1]}"
            """#)
            // The far Mac's login shell, answering `command -v claude`.
            install(shell, "#!/bin/sh\nprintf 'motd noise from a login script\\n'\nprintf 'CROOK_PATH=%s\\n' \"$CROOK_STUB_FAR_PATH\"\nprintf '%s\\n' \"$CROOK_STUB_CLAUDE\"\n")
            verified = bin.appendingPathComponent("verified/claude")
            try? fm.createDirectory(at: verified.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: claude, to: verified)
        }

        private func install(_ url: URL, _ text: String) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func environment(stubOnPath: Bool = true, claudeOnFarMac: String? = nil, exit: Int32 = 0,
                         farPath: String = "") -> [String: String] {
            [
                "HOME": dir.path,
                "PATH": (stubOnPath ? bin.path + ":" : "") + "/usr/bin:/bin:/usr/sbin:/sbin",
                "SHELL": shell.path,
                "CROOK_STUB_OUT": out.path,
                "CROOK_STUB_EXIT": String(exit),
                "CROOK_STUB_CLAUDE": claudeOnFarMac ?? claude.path,
                "CROOK_STUB_FAR_PATH": farPath,
            ]
        }

        func session(_ name: String) -> URL {
            dir.appendingPathComponent("sessions/\(name)", isDirectory: true)
        }

        func reset() {
            try? fm.removeItem(at: out)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        }

        func args() -> [String]? { fields(out.appendingPathComponent("args")) }
        func sshArgs() -> [String]? { fields(out.appendingPathComponent("ssh-args")) }
        func cwd() -> String? { try? String(contentsOf: out.appendingPathComponent("cwd"), encoding: .utf8) }
        func which() -> String? { try? String(contentsOf: out.appendingPathComponent("which"), encoding: .utf8) }
        func path() -> String? { try? String(contentsOf: out.appendingPathComponent("path"), encoding: .utf8) }

        private func fields(_ url: URL) -> [String]? {
            guard let d = try? Data(contentsOf: url) else { return nil }
            var parts = d.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            if parts.last == "" { parts.removeLast() }
            return parts
        }

        deinit { try? FileManager.default.removeItem(at: dir) }
    }

    /// Run a session folder's launch.command as Terminal would, minus Terminal.
    @discardableResult
    private static func runRunner(_ folder: URL, _ env: [String: String], timeout: TimeInterval = 30) -> SessionRunner.Exit? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [folder.appendingPathComponent("launch.command").path]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        return (try? String(contentsOf: folder.appendingPathComponent("exit"), encoding: .utf8))
            .flatMap(SessionRunner.parseExit)
    }

    private static func prepare(_ folder: URL, _ command: TerminalLauncher.Command,
                                _ args: [String], ssh: URL? = nil) -> Bool {
        do {
            try TerminalLauncher.prepare(folder: folder, command: command, claudeArguments: args,
                                         frame: nil, bundleID: nil, includeWindowScript: false,
                                         sshPath: ssh?.path ?? "/usr/bin/ssh")
            return true
        } catch {
            T.ok("CR-00  a session folder is written", false, "\(error)")
            return false
        }
    }

    static func run() {
        T.suite("claude-runner — this Mac")
        let bench = Bench()
        let project = bench.dir.appendingPathComponent("my project (2026)", isDirectory: true)
        try? fm.createDirectory(at: project, withIntermediateDirectories: true)
        let pwned = bench.dir.appendingPathComponent("pwned")
        let hostile = "It's \"quoted\" $(touch \(pwned.path)) `touch \(pwned.path)` ; echo hi | cat\n"
            + "\tsecond line * ? [a] {b} ü 日本 \\ -dash\n\n"
        let args = ["--name", "Crook: SKILL.md — ü", "--append-system-prompt", "line one\nline two\n", "--", hostile]

        let local = bench.session("local")
        guard prepare(local, .local(workingDirectory: project.path, claudePath: "/nonexistent/claude"), args) else { return }
        T.eq("CR-01  the runner reports a clean exit, finding claude on PATH when Crook's path is gone", runRunner(local, bench.environment())?.status, 0)
        T.eq("CR-02  claude runs in the working folder, spaces and all", bench.cwd(), project.path)
        T.eq("CR-03  every argument arrives byte for byte", bench.args(), args)
        T.ok("CR-04  nothing in them was ever run as code", !fm.fileExists(atPath: pwned.path))
        T.ok("CR-05  the runner and the program it ran are both on record",
             fm.fileExists(atPath: local.appendingPathComponent("runner.pid").path)
             && fm.fileExists(atPath: local.appendingPathComponent("child.pid").path))
        T.eq("CR-06  the runner is private to this user",
             (try? fm.attributesOfItem(atPath: local.appendingPathComponent("launch.command").path))?[.posixPermissions] as? Int,
             0o700)

        bench.reset()
        let bigArgs = ["--", String(repeating: "ab'c\"$ `x` ", count: 10_000)]
        let big = bench.session("big")
        _ = prepare(big, .local(workingDirectory: project.path, claudePath: bench.claude.path), bigArgs)
        // No stub on PATH: the path Crook found is the fallback.
        runRunner(big, bench.environment(stubOnPath: false))
        T.eq("CR-07  a 100 KB request survives", bench.args(), bigArgs)

        bench.reset()
        let both = bench.session("both")
        _ = prepare(both, .local(workingDirectory: project.path, claudePath: bench.verified.path), ["--"])
        runRunner(both, bench.environment())
        T.eq("CR-23  the claude Crook checked is the one that runs, even with another on PATH",
             bench.which(), bench.verified.path)

        let failing = bench.session("fails")
        _ = prepare(failing, .local(workingDirectory: project.path, claudePath: bench.claude.path), ["--"])
        T.eq("CR-08  claude's own exit status is what the runner reports",
             runRunner(failing, bench.environment(exit: 1))?.status, 1)

        let missing = bench.session("missing")
        _ = prepare(missing, .local(workingDirectory: project.path, claudePath: "/nonexistent/claude"), [])
        T.eq("CR-09  no claude anywhere is 90", runRunner(missing, bench.environment(stubOnPath: false))?.status, 90)

        let gone = bench.session("gone")
        _ = prepare(gone, .local(workingDirectory: bench.dir.appendingPathComponent("deleted").path,
                                 claudePath: bench.claude.path), [])
        T.eq("CR-10  a working folder that is gone is 91", runRunner(gone, bench.environment())?.status, 91)

        let locked = bench.dir.appendingPathComponent("locked", isDirectory: true)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o100], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let denied = bench.session("denied")
        _ = prepare(denied, .local(workingDirectory: locked.path, claudePath: bench.claude.path), [])
        T.eq("CR-11  a folder it may enter but not read is 92, the shape a privacy denial takes",
             runRunner(denied, bench.environment())?.status, 92)

        T.suite("claude-runner — another Mac")
        bench.reset()
        let remote = bench.session("remote")
        _ = prepare(remote, .remote(host: "mac-mini", workingDirectory: project.path), args, ssh: bench.ssh)
        T.eq("CR-12  the far side's clean exit comes back through ssh",
             runRunner(remote, bench.environment(stubOnPath: false))?.status, 0)
        let ssh = bench.sshArgs() ?? []
        let optionCount = SSHTransport.connectionOptions.count
        T.ok("CR-13  ssh gets a terminal, Crook's own connection options, then -- and the host",
             ssh.first == "-t"
             && Array(ssh.dropFirst().prefix(optionCount)) == SSHTransport.connectionOptions
             && ssh.count == optionCount + 4 && ssh[optionCount + 1] == "--" && ssh[optionCount + 2] == "mac-mini",
             ssh.dropLast().joined(separator: " | "))
        T.ok("CR-14  the remote command is a fixed template with nothing of the request in it",
             (ssh.last ?? "").hasPrefix("/bin/sh -c 'exec /bin/zsh -fc ") && !(ssh.last ?? "").contains("quoted"))
        T.eq("CR-15  claude on the far Mac starts in the working folder", bench.cwd(), project.path)
        T.eq("CR-16  and receives every argument byte for byte", bench.args(), args)
        T.ok("CR-17  and nothing in them ran as code there either", !fm.fileExists(atPath: pwned.path))

        bench.reset()
        let farPath = bench.session("remote-path")
        _ = prepare(farPath, .remote(host: "mac-mini", workingDirectory: project.path), ["--"], ssh: bench.ssh)
        runRunner(farPath, bench.environment(stubOnPath: false, farPath: "/far/homebrew/bin:/usr/bin:/bin"))
        T.eq("CR-24  claude on the far Mac gets that Mac's login PATH, so its MCP servers and hooks resolve",
             bench.path(), "/far/homebrew/bin:/usr/bin:/bin")

        let rgone = bench.session("remote-gone")
        _ = prepare(rgone, .remote(host: "mac-mini", workingDirectory: "/nowhere/at/all"), [], ssh: bench.ssh)
        T.eq("CR-18  a project folder missing on the far Mac is 91",
             runRunner(rgone, bench.environment(stubOnPath: false))?.status, 91)

        if let system = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first(where: { fm.isExecutableFile(atPath: $0) }) {
            T.skip("CR-19  no claude on the far Mac is 90", "\(system) exists on this machine")
        } else {
            let rmissing = bench.session("remote-missing")
            _ = prepare(rmissing, .remote(host: "mac-mini", workingDirectory: project.path), [], ssh: bench.ssh)
            T.eq("CR-19  no claude on the far Mac is 90",
                 runRunner(rmissing, bench.environment(stubOnPath: false, claudeOnFarMac: ""))?.status, 90)
        }

        T.suite("claude-runner — the scripts themselves")
        T.ok("CR-20  the local runner is valid zsh", zshParses(SessionRunner.localScript))
        T.ok("CR-21  the remote runner is valid zsh", zshParses(SessionRunner.remoteScript))
        T.ok("CR-22  the window script is valid AppleScript", appleScriptCompiles(SessionRunner.windowScript))
    }

    private static func zshParses(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-n", "-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Compiles without running: osacompile checks syntax and never sends an
    /// event to Terminal.
    private static func appleScriptCompiles(_ script: String) -> Bool {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("crook-osa-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("w.applescript")
        try? script.write(to: src, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        p.arguments = ["-o", dir.appendingPathComponent("w.scpt").path, src.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func outcomes() {
        T.suite("claude-exit — what an ending means")
        typealias E = SessionRunner.Exit
        func o(_ exit: E?, end: Bool = false, remote: Bool = false, changed: Bool = false) -> SessionRunner.Outcome {
            SessionRunner.outcome(exit: exit, endRequested: end, isRemote: remote, fileChanged: changed)
        }
        T.eq("CX-01  /exit is finished", o(E(status: 0, seconds: 40)), .finished)
        T.eq("CX-02  so is Ctrl-C", o(E(status: 130, seconds: 40)), .finished)
        T.eq("CX-03  a closed window leaves no report, and that is finished too", o(nil), .finished)
        T.eq("CX-04  End Session is finished, whatever the signal did", o(E(status: 143, seconds: 9), end: true), .finished)
        T.eq("CX-05  90 is Claude Code missing", o(E(status: 90, seconds: 0)), .claudeMissing)
        T.eq("CX-06  91 is the folder missing", o(E(status: 91, seconds: 0)), .folderMissing)
        T.eq("CX-07  92 is folder access", o(E(status: 92, seconds: 0)), .folderAccess)
        T.eq("CX-08  ssh failing at once could not connect", o(E(status: 255, seconds: 2), remote: true), .couldNotConnect)
        T.eq("CX-09  ssh failing later lost the connection", o(E(status: 255, seconds: 600), remote: true), .connectionLost)
        T.eq("CX-10  declining trust, file untouched: closed without changes", o(E(status: 1, seconds: 3)), .closedWithoutChanges)
        T.eq("CX-11  an error after changes: stopped unexpectedly", o(E(status: 1, seconds: 300), changed: true), .stoppedUnexpectedly)
        T.eq("CX-12  255 on this Mac is Claude Code's, not ssh's", o(E(status: 255, seconds: 2)), .closedWithoutChanges)
        T.ok("CX-13  the report is read back as written",
             SessionRunner.parseExit("143 12\n") == E(status: 143, seconds: 12) && SessionRunner.parseExit("garbage") == nil)
    }

    static func placement() {
        T.suite("claude-placement — Terminal beside Crook")
        // Everything in AppKit's global coordinates, the space Terminal's
        // `frame` speaks (check S2: its `bounds` does not convert reliably
        // across displays).
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)   // 14-inch MacBook Pro, less the menu bar
        let primary: CGFloat = 982
        let roomy = TerminalLauncher.placement(crook: CGRect(x: 40, y: 100, width: 800, height: 700), visible: visible)
        T.ok("CL-01  room on the right: Terminal goes there and Crook stays put",
             roomy.crook == nil && roomy.terminal == CGRect(x: 840, y: 100, width: 672, height: 700), "\(roomy)")
        let rightHeavy = TerminalLauncher.placement(crook: CGRect(x: 700, y: 100, width: 800, height: 700), visible: visible)
        T.ok("CL-02  room only on the left: Terminal goes there instead",
             rightHeavy.crook == nil && rightHeavy.terminal.maxX == 700 && rightHeavy.terminal.width == 700, "\(rightHeavy)")
        let wide = TerminalLauncher.placement(crook: CGRect(x: 100, y: 50, width: 1300, height: 850), visible: visible)
        T.ok("CL-03  no room: Crook moves to the left edge and narrows only as far as it must",
             wide.crook == CGRect(x: 0, y: 50, width: 952, height: 850), "\(wide)")
        T.ok("CL-04  and Terminal takes the rest",
             wide.terminal == CGRect(x: 952, y: 50, width: 560, height: 850), "\(wide)")
        let tiny = TerminalLauncher.placement(crook: CGRect(x: 0, y: 0, width: 1100, height: 700),
                                              visible: CGRect(x: 0, y: 0, width: 1200, height: 760), crookMinWidth: 720)
        T.ok("CL-05  never narrower than Crook's minimum, overlapping on a screen that small",
             tiny.crook?.width == 720 && tiny.terminal.width == 560 && tiny.terminal.maxX == 1200, "\(tiny)")
        let second = TerminalLauncher.placement(crook: CGRect(x: -3000, y: 200, width: 1200, height: 900),
                                                visible: CGRect(x: -3440, y: 17, width: 3440, height: 1377))
        T.ok("CL-06  on a display left of the main one, coordinates stay global",
             second.crook == nil && second.terminal == CGRect(x: -1800, y: 200, width: 760, height: 900), "\(second)")
        // The window server reports frames top-left; 982 - 190 - 690 = 102, within a few points of 100.
        T.ok("CL-07  landing within a few points counts; landing somewhere else does not",
             TerminalLauncher.landed(CGRect(x: 845, y: 190, width: 680, height: 690), near: roomy.terminal, primaryHeight: primary)
             && !TerminalLauncher.landed(CGRect(x: 845, y: 33, width: 680, height: 690), near: roomy.terminal, primaryHeight: primary)
             && !TerminalLauncher.landed(nil, near: roomy.terminal, primaryHeight: primary))
        T.eq("CL-08  the runner is handed left, bottom, right, top",
             TerminalLauncher.frameEdges(CGRect(x: -560, y: 300, width: 560, height: 900)), "-560 300 0 1200")
    }
}
