import Foundation

/// Reviewing a session: which lines light up, what the banner and alerts say,
/// and putting bytes back exactly.
enum ClaudeReviewTests {

    static func run() {
        T.suite("claude-review — which lines light up")
        let hundred = (1...100).map { "line \($0)" }
        let before = hundred.joined(separator: "\n") + "\n"
        var renamed = hundred
        renamed[2] = "LINE 3"
        renamed[79] = "LINE 80"
        let after = renamed.joined(separator: "\n") + "\n"
        T.eq("CV-01  a rename on line 3 and line 80 lights two lines, not seventy-eight",
             SessionReview.changedLines(before: before, after: after), [3, 80])
        var removed = hundred
        removed.remove(at: 9)
        T.eq("CV-02  a removed line lights the line that took its place",
             SessionReview.changedLines(before: before, after: removed.joined(separator: "\n") + "\n"), [10])
        var inserted = hundred
        inserted.insert("new", at: 50)
        T.eq("CV-03  an inserted line lights itself",
             SessionReview.changedLines(before: before, after: inserted.joined(separator: "\n") + "\n"), [51])
        T.eq("CV-04  removing the last line lights the new last line",
             SessionReview.changedLines(before: "a\nb\nc", after: "a\nb"), [2])
        T.eq("CV-05  no change lights nothing", SessionReview.changedLines(before: before, after: before), [])
        var sevenHundred = (1...700).map { "line \($0)" }
        let longBefore = sevenHundred.joined(separator: "\n") + "\n"
        sevenHundred[2] = "LINE 3"
        sevenHundred[697] = "LINE 698"
        T.eq("CV-36  and in a 700-line file, still two lines, not the 696 between",
             SessionReview.changedLines(before: longBefore, after: sevenHundred.joined(separator: "\n") + "\n"), [3, 698])
        let t = SessionReview.tally(baseline: before, current: after)
        T.ok("CV-06  the tally counts lines added and removed", t.added == 2 && t.removed == 2, "\(t)")

        T.suite("claude-review — the banner says")
        func facts(_ state: ClaudeSession.State, added: Int = 0, removed: Int = 0, vanished: Bool = false,
                   nudging: Bool = false, undo: SessionCopy.Availability? = .available,
                   redo: SessionCopy.Availability? = .available, also: [String] = [],
                   asks: Bool = false) -> SessionCopy.BannerFacts {
            .init(state: state, added: added, removed: removed, fileVanished: vanished, machineName: "mac-mini",
                  nudging: nudging, undo: undo, redo: redo, alsoChanged: also, asksBeforeEditing: asks)
        }
        func titles(_ c: BannerContent?) -> [String] { c?.buttons.map(\.title) ?? [] }

        T.eq("CV-07  opening", SessionCopy.banner(facts(.opening))?.title, "Opening Claude Code in Terminal…")
        let running = SessionCopy.banner(facts(.running))
        T.ok("CV-08  running, before any change",
             running?.title == "Editing with Claude in Terminal" && running?.note == "Read-only here until you finish"
             && titles(running) == ["Show Terminal", "End Session"])
        T.eq("CV-09  running, after changes", SessionCopy.banner(facts(.running, added: 12, removed: 4))?.note,
             "+12 −4 so far · read-only until you finish")
        T.eq("CV-10  someone tried to type", SessionCopy.banner(facts(.running, nudging: true))?.note,
             "To edit it yourself, finish in Terminal or click End Session")
        T.eq("CV-11  Claude moved the file", SessionCopy.banner(facts(.running, vanished: true))?.title,
             "Claude moved or deleted this file")
        T.eq("CV-34  a file Claude Code asks about says where the question is, until the first change lands",
             SessionCopy.banner(facts(.running, asks: true))?.note, "Claude Code asks in Terminal before changing it")
        T.eq("CV-35  then counts changes like any other",
             SessionCopy.banner(facts(.running, added: 2, removed: 1, asks: true))?.note,
             "+2 −1 so far · read-only until you finish")
        let done = SessionCopy.banner(facts(.ended(.finished), added: 14, removed: 6,
                                            also: ["CLAUDE.md", "commands/ship.md"]))
        T.ok("CV-12  finished with changes",
             done?.title == "Finished editing with Claude" && done?.note == "+14 −6 in this file"
             && titles(done) == ["Review Changes", "Undo Changes", "Done"]
             && done?.alsoChanged == ["CLAUDE.md", "commands/ship.md"])
        let unchanged = SessionCopy.banner(facts(.ended(.finished)))
        T.ok("CV-13  finished without changes offers only Done",
             unchanged?.note == "This file wasn't changed" && titles(unchanged) == ["Done"])
        let lost = SessionCopy.banner(facts(.ended(.connectionLost), added: 3, removed: 1,
                                            undo: .unavailable("Reconnect to mac-mini to undo.")))
        T.ok("CV-14  a lost connection names the Mac, and Undo waits for it",
             lost?.title == "The connection to mac-mini closed, which ended the session"
             && lost?.note == "+3 −1 saved before it closed"
             && lost?.buttons.first(where: { $0.action == .undo })?.enabled == false)
        let restored = SessionCopy.banner(facts(.restored(.finished)))
        T.ok("CV-15  after Undo, Redo",
             restored?.title == "Restored the version from before Claude's changes"
             && titles(restored) == ["Redo Changes", "Done"])
        T.ok("CV-16  failures are alerts, not banners",
             SessionCopy.banner(facts(.ended(.closedWithoutChanges))) == nil
             && SessionCopy.banner(facts(.ended(.claudeMissing))) == nil)
        T.eq("CV-17  Undo is only offered while the disk still holds Claude's version",
             SessionCopy.swapAvailability(verb: "undo", haveVersion: true, fileVanished: false, connected: true, machine: nil, diskMatches: false),
             .unavailable("This file has changed since the session ended."))
        T.ok("CV-18  and never for a file that moved",
             SessionCopy.swapAvailability(verb: "undo", haveVersion: true, fileVanished: true, connected: true, machine: nil, diskMatches: true) == nil)
        T.ok("CV-30  nor when Crook never saw Claude's version, as after a session that ended while Crook was closed",
             SessionCopy.swapAvailability(verb: "undo", haveVersion: false, fileVanished: false, connected: true, machine: nil, diskMatches: true) == nil)
        T.eq("CV-31  a reload that failed says so, and keeps the edits",
             SessionCopy.couldNotReadDisk(fileName: "SKILL.md").title, "Couldn't read SKILL.md from disk.")
        T.eq("CV-32  VoiceOver hears a range for neighbouring lines",
             SessionCopy.changedAnnouncement([5, 6, 7]), "Claude changed lines 5 to 7.")
        T.eq("CV-33  and a count for scattered ones, not a range that sounds like everything between",
             SessionCopy.changedAnnouncement([3, 80]), "Claude changed 2 lines.")

        T.suite("claude-review — the alerts say")
        T.eq("CV-19  missing on this Mac", SessionCopy.missing(machine: nil).title, "Claude Code isn't installed on this Mac.")
        T.eq("CV-20  missing on the other Mac names it", SessionCopy.missing(machine: "mac-mini").message,
             "Claude works on the Mac where the file lives. Install Claude Code on mac-mini, then try again.")
        T.eq("CV-21  declining trust offers to try again", SessionCopy.closedWithoutChanges.buttons, ["Try Again", "OK"])
        T.eq("CV-22  a privacy denial names the protected folder",
             SessionCopy.alert(for: .folderAccess, machine: nil,
                               protectedFolder: SessionReview.protectedFolder(for: "/Users/alice/Desktop/atlas", home: "/Users/alice"))?.message,
             "macOS hasn't given Terminal access to your Desktop folder. Turn it on in System Settings, then try again.")
        T.ok("CV-23  a finished session is not an alert",
             SessionCopy.alert(for: .finished, machine: nil, protectedFolder: nil) == nil)
        T.eq("CV-37  Claude Code not starting offers to try again", SessionCopy.didNotStart.buttons, ["Try Again", "OK"])
        T.eq("CV-38  Undo that finds the file changed says nothing was overwritten",
             SessionCopy.swapRefused(fileName: "SKILL.md", restoring: true).message,
             "Undo would overwrite those changes, so Crook left the file as it is.")
        T.eq("CV-39  one line is one line", SessionCopy.endedAnnouncement(added: 1, removed: 0),
             "Claude's session has ended. 1 line added, 0 removed.")
        T.eq("CV-24  too old says which version is needed and which is there",
             SessionCopy.tooOld(machine: nil, installed: "2.0.1").message,
             "Edit with Claude needs version \(ClaudePreflight.minimumVersion) or later. This Mac has 2.0.1.")

        T.suite("claude-review — putting bytes back")
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-undo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("SKILL.md").path
        let baseline = Data([0xEF, 0xBB, 0xBF]) + Data("---\r\nname: x\r\n---\r\n# Title  \r\nno final newline".utf8)
        let claudes = Data("---\nname: x\n---\n# Title\n- [ ] step\n".utf8)
        try? claudes.write(to: URL(fileURLWithPath: path))
        let local = LocalProvider()
        let undone = (try? SessionReview.replace(path: path, on: local, expecting: claudes, with: baseline)) ?? false
        T.ok("CV-25  Undo puts the baseline back byte for byte: BOM, CRLF, trailing spaces, no final newline",
             undone && fm.contents(atPath: path) == baseline)
        let redone = (try? SessionReview.replace(path: path, on: local, expecting: baseline, with: claudes)) ?? false
        T.ok("CV-26  Redo puts Claude's version back", redone && fm.contents(atPath: path) == claudes)
        let someoneElse = Data("someone else wrote this\n".utf8)
        try? someoneElse.write(to: URL(fileURLWithPath: path))
        let refused = (try? SessionReview.replace(path: path, on: local, expecting: claudes, with: baseline)) ?? true
        T.ok("CV-27  neither overwrites a version it did not expect",
             !refused && fm.contents(atPath: path) == someoneElse)

        // CLAUDE.md -> AGENTS.md is a real pattern, and the one Crook already
        // models for reach. An atomic write renames over the path it is given,
        // which turns the link into a plain file and leaves the two names
        // silently disagreeing.
        let agents = dir.appendingPathComponent("AGENTS.md").path
        let link = dir.appendingPathComponent("CLAUDE.md").path
        try? claudes.write(to: URL(fileURLWithPath: agents))
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: "AGENTS.md")
        try? fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: agents)
        _ = agents.withCString { p in setxattr(p, "com.newvisiondevgrp.crook-test", "kept", 4, 0, 0) }
        let throughLink = (try? SessionReview.replace(path: link, on: local, expecting: claudes, with: baseline)) ?? false
        T.ok("CV-28  writing through a symlink keeps the link, and changes what it points at",
             throughLink && (try? fm.destinationOfSymbolicLink(atPath: link)) == "AGENTS.md"
             && fm.contents(atPath: agents) == baseline)
        var tag = [UInt8](repeating: 0, count: 8)
        let tagLength = agents.withCString { p in getxattr(p, "com.newvisiondevgrp.crook-test", &tag, tag.count, 0, 0) }
        // A file shared through a group, as in /Users/Shared: the swap used to
        // hand it the staging folder's group and drop the group's access.
        let shared = dir.appendingPathComponent("shared.md").path
        try? claudes.write(to: URL(fileURLWithPath: shared))
        let otherGroup = getgroups(0, nil) > 0 ? { () -> gid_t? in
            var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
            let n = getgroups(Int32(groups.count), &groups)
            return groups.prefix(Int(max(0, n))).first { $0 != getegid() }
        }() : nil
        if let g = otherGroup, chown(shared, getuid(), g) == 0 {
            try? fm.setAttributes([.posixPermissions: 0o664], ofItemAtPath: shared)
            let wrote = (try? SessionReview.replace(path: shared, on: local, expecting: claudes, with: baseline)) ?? false
            let attrs = try? fm.attributesOfItem(atPath: shared)
            T.ok("CV-40  and a file shared through a group keeps that group and the group's access",
                 wrote && (attrs?[.groupOwnerAccountID] as? UInt32) == g && (attrs?[.posixPermissions] as? Int) == 0o664,
                 "\(String(describing: attrs?[.groupOwnerAccountID])) \(String(describing: attrs?[.posixPermissions]))")
        } else {
            T.skip("CV-40  a file shared through a group keeps its group", "this user belongs to no second group")
        }
        let asFolder = dir.appendingPathComponent("folder-link.md").path
        try? fm.createDirectory(atPath: dir.appendingPathComponent("real-folder/inner").path, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: asFolder, withDestinationPath: "real-folder")
        let folderRefused = (try? local.write(Data("x".utf8), to: asFolder)) == nil
        T.ok("CV-41  and a link that names a folder is never replaced by a file",
             folderRefused && fm.fileExists(atPath: dir.appendingPathComponent("real-folder/inner").path))
        // NSDocument keeps the link's own date and compares that before it
        // saves. The target's date in its place made each save of a linked
        // CLAUDE.md ask about a change by "another application".
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        var times = [timeval(tv_sec: Int(oldDate.timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: Int(oldDate.timeIntervalSince1970), tv_usec: 0)]
        _ = link.withCString { lutimes($0, &times) }
        T.eq("CV-42  a linked document's date is the link's own, as NSDocument keeps it",
             CrookDocument.diskModificationDate(URL(fileURLWithPath: link)), oldDate)
        T.ok("CV-29  and keeps the file's permissions and extended attributes",
             ((try? fm.attributesOfItem(atPath: agents))?[.posixPermissions] as? Int) == 0o640
             && tagLength == 4 && String(decoding: tag.prefix(4), as: UTF8.self) == "kept")
    }
}
