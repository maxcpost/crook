import Foundation

/// Whether Claude Code can run on the Mac that holds the file, answered before
/// any Terminal window opens.
///
/// "Not installed" is a sentence in Crook that names the Mac and the fix.
/// Found out any later, it would be `command not found` in a window someone
/// may never have used.
enum ClaudePreflight {

    enum Result: Equatable {
        case ready(path: String, version: String)
        case missing
        case tooOld(version: String)
    }

    /// The oldest Claude Code this feature was verified against (check S4):
    /// an appended system prompt honoured interactively, the first message sent
    /// after the trust question, and a one-file Edit rule.
    static let minimumVersion = "2.1.268"

    /// Where the installers put it: the native installer, Homebrew on either
    /// architecture, and the old per-user npm location.
    static func knownLocations(home: String) -> [String] {
        [home + "/.local/bin/claude"] + systemLocations + [home + "/.claude/local/claude"]
    }

    /// Homebrew's two prefixes. A variable so the tests can set a machine's own
    /// install aside and exercise the not-installed path on any Mac.
    nonisolated(unsafe) static var systemLocations = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    /// `claude --version` prints "2.1.268 (Claude Code)".
    static func version(from output: String) -> String? {
        guard let token = output.split(whereSeparator: { $0 == " " || $0 == "\n" }).first else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return String(token)
    }

    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    static func judge(path: String?, versionOutput: String) -> Result {
        guard let path, !path.isEmpty, let v = version(from: versionOutput) else { return .missing }
        return isAtLeast(v, minimumVersion) ? .ready(path: path, version: v) : .tooOld(version: v)
    }

    // MARK: - this Mac

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (path: String, version: String)?

    /// Blocks for up to a few seconds the first time; call it off the main
    /// thread. A good answer is remembered until Crook quits, and asked again
    /// if that path stops existing.
    static func checkLocal(home: String = Paths.home, loginShell: String = ClaudePreflight.loginShell()) -> Result {
        cacheLock.lock(); let known = cached; cacheLock.unlock()
        if let known, FileManager.default.isExecutableFile(atPath: known.path) {
            return .ready(path: known.path, version: known.version)
        }
        var path = knownLocations(home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
        if path == nil {
            // Installed somewhere else: ask the person's own shell, the way
            // Terminal will. Interactive, because installers add to PATH in
            // .zshrc — and bounded, because an rc file can wait forever.
            let out = run(loginShell, ["-lic", "command -v claude"], timeout: 3)
            if let last = out.split(separator: "\n").last?.trimmingCharacters(in: .whitespacesAndNewlines),
               last.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: last) {
                path = last
            }
        }
        guard let path else { return .missing }
        let result = judge(path: path, versionOutput: run(path, ["--version"], timeout: 4))
        if case .ready(let p, let v) = result {
            cacheLock.lock(); cached = (p, v); cacheLock.unlock()
        }
        return result
    }

    /// After an update, the remembered version is no longer the installed one.
    static func forgetCachedInstall() {
        cacheLock.lock(); cached = nil; cacheLock.unlock()
    }

    /// From the account record rather than $SHELL, which an app opened from
    /// the Dock is not guaranteed to have.
    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(cString: shell)
            if !s.isEmpty { return s }
        }
        return "/bin/zsh"
    }

    /// Run a program with a hard time limit and return what it printed.
    ///
    /// Output goes to a file, not a pipe. An interactive shell can leave a
    /// background helper holding a pipe open long after it exits, and a read
    /// that waits for the pipe to close would wait for that helper too.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String {
        let fm = FileManager.default
        let capture = fm.temporaryDirectory.appendingPathComponent("crook-preflight-\(UUID().uuidString)")
        guard fm.createFile(atPath: capture.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: capture) else { return "" }
        defer { try? fm.removeItem(at: capture) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { try? handle.close(); return "" }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // SIGKILL, not terminate(): an interactive shell ignores SIGTERM.
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
        try? handle.close()
        return (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
    }

    // MARK: - another Mac

    /// Prints marked lines: where claude is, and what `claude --version` said.
    static let remoteScript = "emulate -R zsh\n" + SessionRunner.resolveClaude + #"""
    crook_resolve_claude
    print -r -- "CROOK_CLAUDE=$CROOK_EXE"
    if [[ -n $CROOK_EXE ]]; then
      print -r -- "CROOK_VERSION=$(/usr/bin/perl -e 'alarm 10; exec @ARGV' "$CROOK_EXE" --version 2>/dev/null | /usr/bin/head -n 1)"
    fi
    exit 0

    """#

    /// The same fixed template the runner uses, so nothing is quoted here either.
    static func remoteCommand() -> String {
        let script = Data(remoteScript.utf8).base64EncodedString()
        return "/bin/sh -c 'exec /bin/zsh -fc \"$(printf %s \(script) | /usr/bin/base64 -D)\"'"
    }

    /// Reads the marked lines, ignoring anything else the far Mac printed.
    static func parseRemote(_ output: String) -> Result {
        var path: String?
        var version = ""
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("CROOK_CLAUDE=") { path = String(line.dropFirst("CROOK_CLAUDE=".count)) }
            if line.hasPrefix("CROOK_VERSION=") { version = String(line.dropFirst("CROOK_VERSION=".count)) }
        }
        guard let path, path.hasPrefix("/") else { return .missing }
        return judge(path: path, versionOutput: version)
    }

    /// Over the connection Crook already holds. nil when the Mac could not be
    /// asked at all, which is a connection problem rather than a missing
    /// install. Blocks; call it off the main thread.
    static func checkRemote(_ transport: SSHTransport) -> Result? {
        let r = transport.runCommand(remoteCommand(), timeout: 25)
        guard r.status == 0 else { return nil }
        return parseRemote(r.out)
    }
}
