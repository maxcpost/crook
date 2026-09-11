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
        T.eq("CF-18  the version is found after a warning printed before it",
             ClaudePreflight.version(from: "Warning: settings.json has a trailing comma\n2.1.300 (Claude Code)\n"), "2.1.300")

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
        // This Mac's own Homebrew or /usr/local install would otherwise answer
        // for the fake home, since every copy is considered.
        let systemLocations = ClaudePreflight.systemLocations
        ClaudePreflight.systemLocations = []
        defer { ClaudePreflight.systemLocations = systemLocations }

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
        do {
            T.eq("CF-09  nothing anywhere is missing",
                 ClaudePreflight.checkLocal(home: home.path, loginShell: silentShell.path), .missing)
            let hanging = script("hanging-shell", "#!/bin/sh\nsleep 30\n")
            let started = Date()
            ClaudePreflight.forgetCachedInstall()
            _ = ClaudePreflight.checkLocal(home: home.path, loginShell: hanging.path)
            let took = Date().timeIntervalSince(started)
            T.ok("CF-10  a login shell that hangs is given up on", took < 9, String(format: "%.1f s", took))

            // Found along the PATH the person's own shell sets up, the way
            // Terminal will find it.
            let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
            try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let newer = elsewhere.appendingPathComponent("claude")
            try? "#!/bin/sh\necho '2.5.0 (Claude Code)'\n".write(to: newer, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newer.path)
            let pathShell = script("path-shell", "#!/bin/sh\necho 'Welcome back'\necho \"alias claude='claude --verbose'\"\necho 'CROOK_PATH=/nowhere:\(elsewhere.path)'\n")

            ClaudePreflight.forgetCachedInstall()
            T.eq("CF-15  an alias named claude doesn't hide the program on the shell's PATH",
                 ClaudePreflight.checkLocal(home: home.path, loginShell: pathShell.path),
                 .ready(path: newer.path, version: "2.5.0"))

            fakeClaude("2.0.1")
            ClaudePreflight.forgetCachedInstall()
            T.eq("CF-16  an old copy where installers put it doesn't hide a newer one on the shell's PATH",
                 ClaudePreflight.checkLocal(home: home.path, loginShell: pathShell.path),
                 .ready(path: newer.path, version: "2.5.0"))

            try? "#!/bin/sh\necho '2.1.0 (Claude Code)'\n".write(to: newer, atomically: true, encoding: .utf8)
            ClaudePreflight.forgetCachedInstall()
            T.eq("CF-19  when every copy is too old, the newest one is named",
                 ClaudePreflight.checkLocal(home: home.path, loginShell: pathShell.path), .tooOld(version: "2.1.0"))
            try? fm.removeItem(atPath: installed)

            // An install that runs through an interpreter kept beside it, as an
            // npm install under nvm does. An app opened from the Dock has only
            // /usr/bin:/bin:/usr/sbin:/sbin, where that interpreter isn't.
            let helper = elsewhere.appendingPathComponent("crook-fake-node")
            try? "#!/bin/sh\necho '2.7.0 (Claude Code)'\n".write(to: helper, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try? "#!/usr/bin/env crook-fake-node\n".write(to: newer, atomically: true, encoding: .utf8)
            ClaudePreflight.forgetCachedInstall()
            T.eq("CF-17  an install that needs a program from its own folder still reports its version",
                 ClaudePreflight.checkLocal(home: home.path, loginShell: pathShell.path),
                 .ready(path: newer.path, version: "2.7.0"))
            try? fm.removeItem(at: newer)

            // The old per-user npm install, whose node lives only on the
            // shell's PATH (nvm): not answerable from where the installer put
            // it, until asked again with that PATH.
            let nodeDir = home.appendingPathComponent("nvm-bin", isDirectory: true)
            try? fm.createDirectory(at: nodeDir, withIntermediateDirectories: true)
            let fakeNode = nodeDir.appendingPathComponent("crook-fake-nvm-node")
            try? "#!/bin/sh\necho '2.8.0 (Claude Code)'\n".write(to: fakeNode, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNode.path)
            let localDir = home.appendingPathComponent(".claude/local", isDirectory: true)
            try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
            let localClaude = localDir.appendingPathComponent("claude")
            try? "#!/usr/bin/env crook-fake-nvm-node\n".write(to: localClaude, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localClaude.path)
            let nvmShell = script("nvm-shell", "#!/bin/sh\necho 'CROOK_PATH=\(nodeDir.path):/usr/bin:/bin'\n")
            ClaudePreflight.forgetCachedInstall()
            T.eq("CF-20  an old npm install that needs node from the shell's PATH is found",
                 ClaudePreflight.checkLocal(home: home.path, loginShell: nvmShell.path),
                 .ready(path: localClaude.path, version: "2.8.0"))
            try? fm.removeItem(at: localClaude)
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
        // A real probe run through /bin/sh, with claude only on that shell's
        // PATH, so the answer can't come from where installers put it.
        let farBin = home.appendingPathComponent("far-bin", isDirectory: true)
        try? fm.createDirectory(at: farBin, withIntermediateDirectories: true)
        let farClaude = farBin.appendingPathComponent("claude")
        try? "#!/bin/sh\necho '2.4.0 (Claude Code)'\n".write(to: farClaude, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: farClaude.path)
        let farShell = script("far-shell", "#!/bin/sh\necho 'a login script that talks'\necho /tmp\nPATH=\(farBin.path):/usr/bin:/bin; export PATH\n/bin/sh -c \"$2\"\n")
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
             .ready(path: farClaude.path, version: "2.4.0"))
    }
}
