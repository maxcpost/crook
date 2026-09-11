import Foundation

/// What Claude Code is told, decided without Terminal.
///
/// Every rule here — where Claude starts, what it may edit without asking, the
/// words it sees first — used to be the kind of thing you check by opening a
/// Terminal and squinting. These pin them down instead.
enum ClaudePlanTests {

    static func run() {
        T.suite("claude-plan — the folder Claude Code starts in")
        let home = "/Users/alice"
        let roots = ["/Users/alice/work/atlas", "/Users/alice/work/atlas/packages/web", "/Users/alice/"]
        T.eq("CP-01  a project file starts in its project",
             SessionPlan.workingDirectory(for: "/Users/alice/work/atlas/CLAUDE.md", roots: roots, home: home),
             "/Users/alice/work/atlas")
        T.eq("CP-02  the deepest project wins when projects nest",
             SessionPlan.workingDirectory(for: "/Users/alice/work/atlas/packages/web/CLAUDE.md", roots: roots, home: home),
             "/Users/alice/work/atlas/packages/web")
        T.eq("CP-03  a personal file starts in ~/.claude, even with the home folder imported as a project",
             SessionPlan.workingDirectory(for: "/Users/alice/.claude/skills/release-notes/SKILL.md", roots: roots, home: home),
             "/Users/alice/.claude")
        T.eq("CP-04  anything else starts in its own folder",
             SessionPlan.workingDirectory(for: "/tmp/notes/idea.md", roots: roots, home: home), "/tmp/notes")
        T.eq("CP-05  a root that is only a prefix of a folder name is not a match",
             SessionPlan.workingDirectory(for: "/Users/alice/work/atlas-relay/CLAUDE.md",
                                          roots: ["/Users/alice/work/atlas"], home: home),
             "/Users/alice/work/atlas-relay")
        T.eq("CP-06  paths are named relative to that folder",
             SessionPlan.relativePath("/Users/alice/.claude/skills/x/SKILL.md", from: "/Users/alice/.claude"),
             "skills/x/SKILL.md")

        T.suite("claude-plan — the first message")
        let rel = "skills/release-notes/SKILL.md"
        T.eq("CP-07  nothing typed, nothing selected",
             SessionPlan.firstMessage(relativePath: rel, lines: nil, request: ""),
             "I'd like to make some changes to skills/release-notes/SKILL.md.")
        T.eq("CP-08  nothing typed, lines selected",
             SessionPlan.firstMessage(relativePath: rel, lines: 12...16, request: "  \n"),
             "I'd like to change lines 12–16 of skills/release-notes/SKILL.md.")
        T.eq("CP-09  a request, nothing selected",
             SessionPlan.firstMessage(relativePath: rel, lines: nil, request: "Make Steps a checklist\n"),
             "In skills/release-notes/SKILL.md: Make Steps a checklist")
        T.eq("CP-10  a request about one selected line",
             SessionPlan.firstMessage(relativePath: rel, lines: 12...12, request: "Shorter"),
             "In line 12 of skills/release-notes/SKILL.md: Shorter")

        T.suite("claude-plan — which lines a selection covers")
        // o0 n1 e2 \n3 | t4 w5 o6 ␠7 🙂8-9 \n10 | t11 h12 r13 e14 e15 \n16
        let text = NSString(string: "one\ntwo 🙂\nthree\n")
        T.ok("CP-11  a caret is not a selection", SessionPlan.selectedLines(in: text, anchor: 5, head: 5) == nil)
        T.ok("CP-12  a word on line 2", SessionPlan.selectedLines(in: text, anchor: 4, head: 7) == 2...2)
        T.ok("CP-13  dragging over whole lines stops at the line it ends on",
             SessionPlan.selectedLines(in: text, anchor: 0, head: 11) == 1...2)
        T.ok("CP-14  a backwards selection is the same selection",
             SessionPlan.selectedLines(in: text, anchor: 13, head: 2) == 1...3)
        T.ok("CP-15  UTF-16 offsets past an emoji still land on the right line",
             SessionPlan.selectedLines(in: text, anchor: 11, head: 16) == 3...3)

        T.suite("claude-plan — permissions and arguments")
        T.eq("CP-16  one Edit rule, anchored at the filesystem root",
             SessionPlan.preapprovalRules(for: "/Users/alice/.claude/CLAUDE.md"),
             ["Edit(//Users/alice/.claude/CLAUDE.md)"])
        T.ok("CP-17  a path that would read as a glob gets no rule",
             SessionPlan.preapprovalRules(for: "/Users/alice/notes [old]/CLAUDE.md").isEmpty
             && SessionPlan.preapprovalRules(for: "/Users/alice/a*b/CLAUDE.md").isEmpty)
        // Claude Code writes the path it edits in composed form. A folder named
        // in decomposed form, as older Macs and copied folders often are, would
        // otherwise never match its own rule.
        let decomposed = "/Users/alice/Re\u{301}sume\u{301}/CLAUDE.md"
        let rules = SessionPlan.preapprovalRules(for: decomposed)
        // Compared as bytes, because String's == treats the two forms as equal.
        let bytes = Set(rules.map { Array($0.utf8) })
        T.ok("CP-30  an accented path is approved in both of the forms it can be written",
             rules.count == 2 && bytes.contains(Array(("Edit(/" + decomposed + ")").utf8))
             && bytes.contains(Array(("Edit(/" + decomposed.precomposedStringWithCanonicalMapping + ")").utf8)),
             "\(rules.map { Array($0.utf8).count })")
        let carried = SessionPlan.permissionSettings(rules)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: [String: [String]]] }?["permissions"]?["allow"]
        T.ok("CP-36  and both forms survive the trip through settings JSON",
             carried.map { Set($0.map { Array($0.utf8) }) } == bytes)

        let id = UUID(uuidString: "5414D6ED-EA49-4E8B-8431-0867AE492537")!
        let plan = SessionPlan.make(.init(
            filePath: "/Users/alice/.claude/skills/release-notes/SKILL.md", projectRoots: roots, home: home,
            machineName: nil, selectedLines: 12...16, request: "Make it a checklist",
            voiceOver: false, sessionID: id))
        let a = plan.arguments
        let pairs = Array(zip(a, a.dropFirst()))
        T.eq("CP-18  the session id is Crook's", Array(a.prefix(2)),
             ["--session-id", "5414d6ed-ea49-4e8b-8431-0867ae492537"])
        T.ok("CP-19  ask before editing anything else, whatever the person's own default",
             pairs.contains { $0 == "--permission-mode" && $1 == "default" })
        func allowed(_ args: [String]) -> [String]? {
            guard let i = args.firstIndex(of: "--settings"), i + 1 < args.count,
                  let json = try? JSONSerialization.jsonObject(with: Data(args[i + 1].utf8)) as? [String: Any],
                  let permissions = json["permissions"] as? [String: Any] else { return nil }
            return permissions["allow"] as? [String]
        }
        T.eq("CP-20  the rule travels as settings",
             allowed(a), ["Edit(//Users/alice/.claude/skills/release-notes/SKILL.md)"])
        // --allowedTools splits its value at a space or comma after a closing
        // parenthesis, and cut this rule in two (checked against 2.1.268).
        let copied = SessionPlan.make(.init(filePath: "/Users/alice/My Notes (copy) it's/CLAUDE.md", projectRoots: [],
                                            home: home, machineName: nil, selectedLines: nil, request: "",
                                            voiceOver: false, sessionID: id))
        T.ok("CP-31  so a folder like “My Notes (copy) it's” arrives in one piece, never through --allowedTools",
             allowed(copied.arguments) == ["Edit(//Users/alice/My Notes (copy) it's/CLAUDE.md)"]
             && !copied.arguments.contains("--allowedTools"))
        let bare = SessionPlan.make(.init(filePath: "/Users/alice/a*b/CLAUDE.md", projectRoots: [], home: home,
                                          machineName: nil, selectedLines: nil, request: "", voiceOver: false, sessionID: id))
        T.ok("CP-32  and no settings at all when there is no rule", !bare.arguments.contains("--settings"))
        T.eq("CP-21  the first message comes last, after --", Array(a.suffix(2)),
             ["--", "In lines 12–16 of skills/release-notes/SKILL.md: Make it a checklist"])
        T.ok("CP-22  no screen-reader flag unless VoiceOver is on", !a.contains("--ax-screen-reader"))
        let spoken = SessionPlan.make(.init(filePath: "/tmp/x.md", projectRoots: [], home: home, machineName: nil,
                                            selectedLines: nil, request: "", voiceOver: true, sessionID: id))
        T.ok("CP-23  and it is there when VoiceOver is", spoken.arguments.contains("--ax-screen-reader"))
        T.ok("CP-24  the system prompt names the file and the selection",
             plan.systemPrompt.contains("  /Users/alice/.claude/skills/release-notes/SKILL.md")
             && plan.systemPrompt.contains("They selected lines 12–16"))
        T.ok("CP-25  and tells Claude to keep the bytes it wasn't asked to change",
             plan.systemPrompt.contains("line endings, indentation, trailing whitespace"))

        // Claude Code asks before editing anything inside a .claude folder, and
        // no rule or permission mode short of skipping every check changes
        // that (checked against 2.1.268). Nobody should be told otherwise.
        T.ok("CP-33  a file inside a .claude folder is one Claude Code asks about",
             SessionPlan.asksBeforeEditing("/Users/alice/.claude/skills/release-notes/SKILL.md")
             && SessionPlan.asksBeforeEditing("/Users/alice/work/atlas/.claude/commands/ship.md")
             && !SessionPlan.asksBeforeEditing("/Users/alice/work/atlas/CLAUDE.md")
             && !SessionPlan.asksBeforeEditing("/Users/alice/work/my.claude/notes.md"))
        T.ok("CP-34  and Claude is told to expect the question, not that the edit is approved",
             plan.systemPrompt.contains("asks them to approve") && !plan.systemPrompt.contains("already approved"))
        T.ok("CP-35  while a file elsewhere is already approved",
             spoken.systemPrompt.contains("already approved") && !spoken.systemPrompt.contains("asks them to approve"))
        T.ok("CP-37  and one that got no rule is never called approved",
             bare.systemPrompt.contains("asks them to approve") && !bare.systemPrompt.contains("already approved"))
        T.ok("CP-38  other files wait for a yes, whatever the person's own settings allow",
             plan.systemPrompt.contains("wait for them to say yes before editing any of them"))

        T.suite("claude-plan — session names")
        T.eq("CP-26  a generic filename carries its folder",
             SessionPlan.sessionName(file: "/Users/alice/.claude/skills/release-notes/SKILL.md", machine: nil),
             "Crook: SKILL.md — release-notes")
        T.eq("CP-27  a distinctive one does not",
             SessionPlan.sessionName(file: "/Users/alice/notes/ideas.md", machine: nil), "Crook: ideas.md")
        T.eq("CP-28  another Mac is named",
             SessionPlan.sessionName(file: "/Users/max/atlas/CLAUDE.md", machine: "mac-mini"),
             "Crook: CLAUDE.md — atlas on mac-mini")
        let long = SessionPlan.sessionName(file: "/x/" + String(repeating: "very-long-name-", count: 8) + ".md", machine: nil)
        T.ok("CP-29  long names are shortened in the middle to 60 characters",
             long.count == 60 && long.contains("…") && long.hasPrefix("Crook: ") && long.hasSuffix(".md"), long)
    }
}
