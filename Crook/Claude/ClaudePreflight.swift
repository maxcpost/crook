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

    /// `claude --version` prints "2.1.268 (Claude Code)". The first word that
    /// is a version, so a warning printed ahead of it doesn't hide it.
    static func version(from output: String) -> String? {
        for token in output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) {
                return String(token)
            }
        }
        return nil
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

    /// Blocks for up to several seconds the first time; call it off the main
    /// thread. A good answer is remembered until Crook quits, and asked again
    /// if that path stops existing.
    ///
    /// Any copy that is new enough will do, because the session runs the copy
    /// found here. Macs collect more than one: a native install beside an old
    /// Homebrew one, or an npm install under nvm.
    static func checkLocal(home: String = Paths.home, loginShell: String = ClaudePreflight.loginShell()) -> Result {
        cacheLock.lock(); let known = cached; cacheLock.unlock()
        if let known, FileManager.default.isExecutableFile(atPath: known.path) {
            return .ready(path: known.path, version: known.version)
        }
        var tried = Set<String>()
        var unanswered: [String] = []
        var newestTooOld: String?
        func consider(_ path: String, shellPath: [String]) -> Result? {
            let real = (path as NSString).resolvingSymlinksInPath
            guard FileManager.default.isExecutableFile(atPath: path), !tried.contains(real) else { return nil }
            // Its own folder first: an install that runs through an interpreter
            // keeps it there, and an app opened from the Dock has only the
            // system's folders on its PATH.
            let search = [(path as NSString).deletingLastPathComponent] + shellPath + fallbackPath
            let output = run(path, ["--version"], timeout: 4, environment: ["PATH": search.joined(separator: ":")])
            switch judge(path: path, versionOutput: output) {
            case .ready(let p, let v):
                tried.insert(real)
                cacheLock.lock(); cached = (p, v); cacheLock.unlock()
                return .ready(path: p, version: v)
            case .tooOld(let v):
                tried.insert(real)
                if newestTooOld.map({ !isAtLeast($0, v) }) ?? true { newestTooOld = v }
                return nil
            case .missing:
                // No version: perhaps it runs through node, and node is only
                // on the shell's PATH (nvm). Asked again once that is known.
                if shellPath.isEmpty { unanswered.append(path) } else { tried.insert(real) }
                return nil
            }
        }

        for path in knownLocations(home: home) {
            if let ready = consider(path, shellPath: []) { return ready }
        }
        // Not where the installers put it, or only an old copy is: look along
        // the PATH the person's own shell sets up, the way Terminal will.
        let shellPath = loginShellPath(loginShell)
        for path in unanswered where !shellPath.isEmpty {
            if let ready = consider(path, shellPath: shellPath) { return ready }
        }
        for dir in shellPath {
            if let ready = consider(dir + "/claude", shellPath: shellPath) { return ready }
        }
        return newestTooOld.map { .tooOld(version: $0) } ?? .missing
    }

    /// The folders a Dock-launched app is missing that installers commonly use.
    static let fallbackPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The PATH an interactive login shell ends up with, read from a marked
    /// line so whatever the rc files print can't be taken for it.
    ///
    /// The PATH itself rather than `command -v claude`, which answers with the
    /// alias when someone has aliased claude. Interactive, because installers
    /// add to PATH in .zshrc; bounded, because an rc file can wait forever —
    /// generously, because one that loads nvm and conda can take seconds.
    static func loginShellPath(_ shell: String) -> [String] {
        let out = run(shell, ["-lic", #"printf '%s\n' "CROOK_PATH=$PATH""#], timeout: 6)
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("CROOK_PATH=") }) else { return [] }
        return line.dropFirst("CROOK_PATH=".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
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
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    environment: [String: String]? = nil) -> String {
        let fm = FileManager.default
        let capture = fm.temporaryDirectory.appendingPathComponent("crook-preflight-\(UUID().uuidString)")
        guard fm.createFile(atPath: capture.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: capture) else { return "" }
        defer { try? fm.removeItem(at: capture) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
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
      # In that Mac's login environment, where anything claude needs to start is.
      crook_apply_login_env
      print -r -- "CROOK_VERSION=$(/usr/bin/perl -e 'alarm 10; exec @ARGV' "$CROOK_EXE" --version 2>/dev/null | /usr/bin/head -n 5 | /usr/bin/tr '\n' ' ')"
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
