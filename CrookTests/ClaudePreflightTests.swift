import Foundation

/// Finding Claude Code before any Terminal window opens — so that "not
/// installed" is a sentence in Crook rather than `command not found` in a
/// window someone may never have used.
enum ClaudePreflightTests {

    static func run() {
        T.suite("claude-preflight — reading a version")
        T.eq("CF-01  the version is the first word", ClaudePreflight.version(from: "2.1.268 (Claude Code)\n"), "2.1.268")
        T.ok("CF-02  output that is not a version is not one",
             ClaudePreflight.version(from: "zsh: command not found: claude") == nil
             && ClaudePreflight.version(from: "") == nil)
        T.ok("CF-03  versions compare as numbers, not text",
             ClaudePreflight.isAtLeast("2.1.268", "2.1.268") && ClaudePreflight.isAtLeast("2.10.0", "2.9.9")
             && !ClaudePreflight.isAtLeast("2.1.99", "2.1.268") && ClaudePreflight.isAtLeast("3", "2.1.268"))
        T.eq("CF-04  new enough is ready",
             ClaudePreflight.judge(path: "/x/claude", versionOutput: "2.2.0 (Claude Code)"),
             .ready(path: "/x/claude", version: "2.2.0"))
        T.eq("CF-05  too old says which version it is",
             ClaudePreflight.judge(path: "/x/claude", versionOutput: "1.0.44 (Claude Code)"), .tooOld(version: "1.0.44"))
        T.eq("CF-06  no path is missing", ClaudePreflight.judge(path: nil, versionOutput: ""), .missing)

        T.suite("claude-preflight — this Mac")
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-preflight-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        func script(_ name: String, _ body: String) -> URL {
            let url = home.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        func fakeClaude(_ version: String) {
            let c = bin.appendingPathComponent("claude")
            try? "#!/bin/sh\necho '\(version) (Claude Code)'\n".write(to: c, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: c.path)
        }
        let silentShell = script("silent-shell", "#!/bin/sh\nexit 0\n")
        let installed = bin.appendingPathComponent("claude").path

        fakeClaude("2.3.0")
        ClaudePreflight.forgetCachedInstall()
        T.eq("CF-07  the native installer's location is found first",
             ClaudePreflight.checkLocal(home: home.path, loginShell: silentShell.path),
             .ready(path: installed, version: "2.3.0"))

        fakeClaude("2.0.1")
        ClaudePreflight.forgetCachedInstall()
        T.eq("CF-08  an old install is reported as old",
             ClaudePreflight.checkLocal(home: home.path, loginShell: silentShell.path), .tooOld(version: "2.0.1"))

        try? fm.removeItem(atPath: installed)
        ClaudePreflight.forgetCachedInstall()
        // This Mac's own Homebrew or /usr/local install would otherwise
        // answer for the fake home; set them aside for these two.
        let systemLocations = ClaudePreflight.systemLocations
        ClaudePreflight.systemLocations = []
        defer { ClaudePreflight.systemLocations = systemLocations }
        do {
            T.eq("CF-09  nothing anywhere is missing",
                 ClaudePreflight.checkLocal(home: home.path, loginShell: silentShell.path), .missing)
            let hanging = script("hanging-shell", "#!/bin/sh\nsleep 30\n")
            let started = Date()
            ClaudePreflight.forgetCachedInstall()
            _ = ClaudePreflight.checkLocal(home: home.path, loginShell: hanging.path)
            let took = Date().timeIntervalSince(started)
            T.ok("CF-10  a login shell that hangs is given up on", took < 6, String(format: "%.1f s", took))
        }

        // The time limit itself, whatever is installed where: a program that
        // prints and then never exits is killed, and what it printed is kept.
        let stuck = script("stuck", "#!/bin/sh\necho partial\nexec sleep 30\n")
        let limitStarted = Date()
        let partial = ClaudePreflight.run(stuck.path, [], timeout: 1)
        let limitTook = Date().timeIntervalSince(limitStarted)
        T.ok("CF-14  a program that never exits is killed at the limit, keeping its output",
             limitTook < 3 && partial == "partial\n", String(format: "%.1f s, %@", limitTook, partial))

        T.suite("claude-preflight — another Mac")
        T.eq("CF-11  a path and a version, found by their markers among whatever a login script printed",
             ClaudePreflight.parseRemote("Welcome to mac-mini\nCROOK_CLAUDE=/Users/max/.local/bin/claude\nCROOK_VERSION=2.1.300 (Claude Code)\n"),
             .ready(path: "/Users/max/.local/bin/claude", version: "2.1.300"))
        T.eq("CF-12  no path is missing", ClaudePreflight.parseRemote("CROOK_CLAUDE=\n"), .missing)

        // The real remote command, run here through /bin/sh the way a login
        // shell on the far Mac runs what ssh hands it.
        fakeClaude("2.4.0")
        let farShell = script("far-shell", "#!/bin/sh\necho 'a login script that talks'\necho CROOK_PATH=/usr/bin:/bin\necho \(installed)\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", ClaudePreflight.remoteCommand()]
        p.environment = ["HOME": home.path, "SHELL": farShell.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        T.eq("CF-13  the remote check finds and reads claude through the base64 template",
             ClaudePreflight.parseRemote(String(decoding: data, as: UTF8.self)),
             .ready(path: installed, version: "2.4.0"))
    }
}
