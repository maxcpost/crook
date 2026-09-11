import AppKit

/// Puts one session on screen.
///
/// Writes the session folder the runner reads, then asks Launch Services to
/// open the runner with Terminal. That is an open, not an Apple Event: Crook
/// needs no permission to do it and nobody is asked anything (check S1).
enum TerminalLauncher {

    enum Command {
        /// `claudePath` is where Crook found it. The runner prefers whatever
        /// the person's own PATH says and falls back to this.
        case local(workingDirectory: String, claudePath: String)
        case remote(host: String, workingDirectory: String)
    }

    static let terminalBundleID = "com.apple.Terminal"

    /// Everything the runner reads, written before Terminal is asked to open it.
    ///
    /// `includeWindowScript` and `sshPath` exist for the tests, which run the
    /// real runner without Terminal and with a stand-in for ssh.
    static func prepare(folder: URL, command: Command, claudeArguments: [String],
                        bounds: CGRect?, bundleID: String?,
                        includeWindowScript: Bool = true, sshPath: String = "/usr/bin/ssh") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        func put(_ name: String, _ data: Data, mode: Int = 0o600) throws {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        switch command {
        case .local(let dir, let claude):
            try put("mode", Data("local".utf8))
            try put("cwd", Data(dir.utf8))
            try put("argv", SessionRunner.encodeFields([claude] + claudeArguments))
        case .remote(let host, let dir):
            try put("mode", Data("remote".utf8))
            let ssh = [sshPath, "-t"] + SSHTransport.connectionOptions
                + [host, SessionRunner.remoteCommand(workingDirectory: dir, arguments: claudeArguments)]
            try put("argv", SessionRunner.encodeFields(ssh))
        }
        if let b = bounds {
            let edges = [b.minX, b.minY, b.maxX, b.maxY].map { String(Int($0.rounded())) }
            try put("bounds", Data(edges.joined(separator: " ").utf8))
        }
        if let bundleID { try put("bundle", Data(bundleID.utf8)) }
        if includeWindowScript { try put("window.applescript", Data(SessionRunner.windowScript.utf8)) }
        try put("launch.command", Data(SessionRunner.localScript.utf8), mode: 0o700)
    }

    /// Always Terminal, whatever the person has set to open `.command` files:
    /// an editor registered for them would show the script instead of running it.
    static func open(folder: URL, completion: @escaping (Error?) -> Void) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
            completion(CocoaError(.fileNoSuchFile))
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([folder.appendingPathComponent("launch.command")],
                                withApplicationAt: terminal, configuration: cfg) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    // MARK: - beside Crook

    struct Placement: Equatable {
        /// Terminal's frame in the top-left-origin global coordinates its
        /// AppleScript `bounds` and CGWindowList both use.
        let terminal: CGRect
        /// Crook's new frame, in AppKit coordinates, when Crook has to make
        /// room; nil when Terminal fits beside it as it is.
        let crook: CGRect?
    }

    /// Where Terminal goes, and whether Crook has to move for it.
    ///
    /// Right if it fits, left if that fits, otherwise Crook slides to the left
    /// edge — narrowing only as far as it must and never below its own minimum
    /// — and Terminal takes the right. `primaryHeight` converts AppKit's
    /// bottom-left origin into the top-left one Terminal speaks.
    static func placement(crook: CGRect, visible: CGRect, primaryHeight: CGFloat,
                          crookMinWidth: CGFloat = 720,
                          terminalMin: CGFloat = 560, terminalMax: CGFloat = 760) -> Placement {
        let top = min(crook.maxY, visible.maxY)
        let bottom = max(crook.minY, visible.minY)
        let height = max(0, top - bottom)
        func topLeft(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }

        let rightRoom = visible.maxX - crook.maxX
        if rightRoom >= terminalMin {
            let w = min(rightRoom, terminalMax)
            return Placement(terminal: topLeft(CGRect(x: crook.maxX, y: bottom, width: w, height: height)),
                             crook: nil)
        }
        let leftRoom = crook.minX - visible.minX
        if leftRoom >= terminalMin {
            let w = min(leftRoom, terminalMax)
            return Placement(terminal: topLeft(CGRect(x: crook.minX - w, y: bottom, width: w, height: height)),
                             crook: nil)
        }
        let crookWidth = max(crookMinWidth, min(crook.width, visible.width - terminalMin))
        let newCrook = CGRect(x: visible.minX, y: bottom, width: crookWidth, height: height)
        let w = max(terminalMin, min(terminalMax, visible.maxX - newCrook.maxX))
        let terminal = CGRect(x: visible.maxX - w, y: bottom, width: w, height: height)
        return Placement(terminal: topLeft(terminal), crook: newCrook)
    }

    /// Where a window actually is, according to the window server.
    ///
    /// Terminal's AppleScript window id is the same number CGWindowList
    /// reports, which is what lets Crook check a placement landed.
    static func frameOfWindow(number: Int) -> CGRect? {
        guard number > 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// Close enough to call it placed. Terminal rounds its size to whole
    /// character cells, so exact equality would never hold.
    static func landed(_ actual: CGRect?, near expected: CGRect, tolerance: CGFloat = 40) -> Bool {
        guard let a = actual else { return false }
        return abs(a.minX - expected.minX) <= tolerance
            && abs(a.minY - expected.minY) <= tolerance
            && abs(a.width - expected.width) <= tolerance
    }
}
