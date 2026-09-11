import Foundation

/// What Claude Code is told about one Edit with Claude session.
///
/// Decided from the facts of a single click — which file, on which machine,
/// which lines were selected, what the person typed — with no window, process
/// or disk involved. That is deliberate: every rule about the folder Claude
/// starts in, what it may edit and the words it sees is a unit test rather than
/// something to try by hand in Terminal.
struct SessionPlan: Equatable {

    struct Input {
        /// Absolute, on the machine that holds the file.
        var filePath: String
        /// The project roots in the sidebar for that machine.
        var projectRoots: [String]
        /// That machine's home directory.
        var home: String
        /// nil for this Mac; otherwise the name the person connected with.
        var machineName: String?
        /// 1-based and inclusive; nil when nothing was selected.
        var selectedLines: ClosedRange<Int>?
        var request: String
        var voiceOver: Bool
        var sessionID: UUID
    }

    let workingDirectory: String
    let relativePath: String
    let sessionName: String
    let firstMessage: String
    let systemPrompt: String
    /// `Edit(//absolute/path)`, or nil when the path would be read as a glob.
    /// Without the rule Claude Code simply asks before editing this file too,
    /// which is the safe direction to be wrong in.
    let preapprovalRule: String?
    /// Everything after the `claude` executable, in order.
    let arguments: [String]

    static func make(_ input: Input) -> SessionPlan {
        let dir = workingDirectory(for: input.filePath, roots: input.projectRoots, home: input.home)
        let rel = relativePath(input.filePath, from: dir)
        let name = sessionName(file: input.filePath, machine: input.machineName)
        let first = firstMessage(relativePath: rel, lines: input.selectedLines, request: input.request)
        let prompt = systemPrompt(file: input.filePath, lines: input.selectedLines)
        let rule = preapprovalRule(for: input.filePath)

        var args = ["--session-id", input.sessionID.uuidString.lowercased(),
                    "--name", name,
                    // Ask before any other edit, whatever the person's own
                    // default is. `default` rather than the `manual` 2.1.268
                    // lists: the same mode, under the name older versions
                    // also accept.
                    "--permission-mode", "default"]
        if let rule { args += ["--allowedTools", rule] }
        args += ["--append-system-prompt", prompt]
        if input.voiceOver { args.append("--ax-screen-reader") }
        // --allowedTools takes any number of values. Without `--`, the first
        // message would be read as one more tool name.
        args += ["--", first]

        return SessionPlan(workingDirectory: dir, relativePath: rel, sessionName: name,
                           firstMessage: first, systemPrompt: prompt,
                           preapprovalRule: rule, arguments: args)
    }

    // MARK: - where Claude Code starts

    /// The project the file belongs to, else `~/.claude` for a personal file,
    /// else the file's own folder.
    ///
    /// The longest match wins, and `~/.claude` competes on the same terms as
    /// the projects. Someone who imported their home folder as a project would
    /// otherwise start every personal-skill session in `~`, where Claude Code
    /// cannot remember trust and asks every single time.
    static func workingDirectory(for file: String, roots: [String], home: String) -> String {
        let candidates = (roots + [home + "/.claude"]).map(trimmingTrailingSlash)
        if let best = candidates
            .filter({ !$0.isEmpty && $0 != "/" && file.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count }) {
            return best
        }
        let parent = (file as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func relativePath(_ file: String, from dir: String) -> String {
        if dir == "/" { return String(file.drop(while: { $0 == "/" })) }
        return file.hasPrefix(dir + "/") ? String(file.dropFirst(dir.count + 1)) : file
    }

    private static func trimmingTrailingSlash(_ p: String) -> String {
        p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    // MARK: - names and words

    /// Filenames that say almost nothing on their own. 21 of the fixture's
    /// files are CLAUDE.md and 34 are SKILL.md; the folder is what identifies
    /// one.
    static let genericNames: Set<String> = [
        "CLAUDE.md", "SKILL.md", "AGENTS.md", "README.md", "MEMORY.md",
        "settings.json", "settings.local.json", ".mcp.json",
    ]

    /// Claude Code shows this in its prompt box and as the Terminal title, so
    /// the window can be told apart from any other Terminal window.
    static func sessionName(file: String, machine: String?) -> String {
        let name = (file as NSString).lastPathComponent
        var s = "Crook: " + name
        if genericNames.contains(name) {
            let folder = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !folder.isEmpty, folder != "/" { s += " — " + folder }
        }
        if let machine { s += " on " + machine }
        return middleTruncated(s, limit: 60)
    }

    static func middleTruncated(_ s: String, limit: Int) -> String {
        guard s.count > limit, limit > 1 else { return s }
        let keep = limit - 1
        let head = (keep + 1) / 2
        return String(s.prefix(head)) + "…" + String(s.suffix(keep - head))
    }

    static func linesPhrase(_ r: ClosedRange<Int>) -> String {
        r.lowerBound == r.upperBound ? "line \(r.lowerBound)" : "lines \(r.lowerBound)–\(r.upperBound)"
    }

    /// Sent as the person's own first message. It names the file relative to
    /// the folder Claude Code starts in, which is how Claude will refer to it
    /// too.
    static func firstMessage(relativePath: String, lines: ClosedRange<Int>?, request: String) -> String {
        let req = request.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (req.isEmpty, lines) {
        case (true, nil):     return "I'd like to make some changes to \(relativePath)."
        case (true, let r?):  return "I'd like to change \(linesPhrase(r)) of \(relativePath)."
        case (false, nil):    return "In \(relativePath): \(req)"
        case (false, let r?): return "In \(linesPhrase(r)) of \(relativePath): \(req)"
        }
    }

    static func systemPrompt(file: String, lines: ClosedRange<Int>?) -> String {
        var head = [
            "This session was opened from Crook, a Mac app for reading and editing the files that configure Claude Code. The person is working on one file:",
            "",
            "  " + file,
        ]
        if let lines { head.append("  They selected \(linesPhrase(lines)) before opening this session.") }
        let rules = [
            "How to work with them:",
            "- Crook shows this file live and highlights each change as you save it. Crook keeps the file read-only while this session is open, so you are the only one editing it.",
            "- Edits to this file are already approved. Change what they ask for and nothing else.",
            "- Keep everything you weren't asked to change exactly as it is: line endings, indentation, trailing whitespace, blank lines, the final newline, and frontmatter fields.",
            "- If their request also needs other files changed (a skill folder renamed, a reference in another CLAUDE.md, a command that points at this file), say which files and why before editing them. Claude Code will ask them to approve each one.",
            "- If their first message doesn't say what to change, read the file and reply in one or two sentences: what the file is for, then ask what they'd like to change. Don't edit anything until they ask.",
            "- After your first change, tell them once, in one short line, that they can type /exit when they're finished to go back to Crook.",
            "- They may not be technical. Use plain words, keep replies short, and describe changes by what they do rather than as diffs.",
        ]
        return (head + [""] + rules).joined(separator: "\n")
    }

    // MARK: - permission

    /// Glob characters would turn the path into a pattern, and a pattern can
    /// match files it was never meant to.
    static func preapprovalRule(for file: String) -> String? {
        guard file.hasPrefix("/"),
              file.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]{}")) == nil else { return nil }
        // `//` anchors an Edit rule at the filesystem root; a single `/` would
        // anchor it at wherever the setting came from.
        return "Edit(/" + file + ")"
    }

    // MARK: - selection

    /// The lines a selection covers, 1-based, or nil for a bare caret.
    ///
    /// Offsets are UTF-16 into Crook's LF-only buffer — the coordinates
    /// CodeMirror and NSString share — so the numbers match the file whatever
    /// its line endings on disk.
    static func selectedLines(in text: NSString, anchor: Int, head: Int) -> ClosedRange<Int>? {
        let from = max(0, min(anchor, head))
        let to = min(text.length, max(anchor, head))
        guard to > from else { return nil }
        let first = newlines(in: text, before: from) + 1
        // The last selected character. A newline belongs to the line it ends,
        // so dragging over whole lines — which finishes at the start of the
        // next one — does not claim that next line.
        let last = newlines(in: text, before: to - 1) + 1
        return first...last
    }

    static func newlines(in text: NSString, before offset: Int) -> Int {
        var count = 0
        var range = NSRange(location: 0, length: max(0, min(offset, text.length)))
        while range.length > 0 {
            let hit = text.range(of: "\n", options: .literal, range: range)
            if hit.location == NSNotFound { break }
            count += 1
            let next = hit.location + 1
            range = NSRange(location: next, length: range.location + range.length - next)
        }
        return count
    }
}
