# Edit with Claude Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A title bar button in Crook that opens Claude Code in Terminal, already pointed at the open file. The file stays live and read-only in Crook while Claude edits it, and when the session ends Crook offers Review, Undo and Redo.

**Architecture:** Pure units decide everything that can be decided without a window:
- `SessionPlan`: what Claude is told.
- `SessionRunner`: the static scripts and what exit codes mean.
- `TerminalLauncher.placement`: where windows go.
- `SessionReview`: highlights, counts and putting bytes back.
- `SessionCopy`: every sentence.

`SessionRegistry` tracks sessions on disk and watches their processes. `SessionController` connects all of that to the one workspace window. The session itself runs in Terminal and outlives Crook.

**Tech Stack:** Swift / AppKit built by `swiftc` via `scripts/build.sh`, with no Xcode project. CodeMirror 6 in `web/src/editor.js`, bundled with esbuild. zsh and AppleScript for the runner. Tests use Crook's own harness (`CrookTests/Harness.swift`, `./scripts/test.sh <suite>`).

**Spec:** `docs/superpowers/specs/2026-09-11-edit-with-claude-design.md`. Read §5 (the flow), §9 (copy), §10 (what Claude is told), §11 (launch mechanics) and §14 (spike results) before starting.

## Global Constraints

- macOS 26 SDK, `-target arm64-apple-macos26.0`; the far Mac is macOS 13+ (the agent's floor).
- Claude Code minimum version: `2.1.268`.
- Claude arguments, in order: `--session-id <uuid> --name <name> --permission-mode default [--allowedTools "Edit(//abs/path)"] --append-system-prompt <text> [--ax-screen-reader] -- <first message>`.
- Session folders live in `~/Library/Caches/Crook/sessions/<uuid>/`, mode 0700. Crook writes nothing into projects.
- No text from a file name, path, machine name or request is ever placed into shell source. It travels as NUL-separated data, and remotely as base64 inside a fixed template.
- Every ssh Crook runs uses `SSHTransport.connectionOptions` exactly.
- Runner exit statuses: 90 claude missing, 91 folder missing, 92 folder access.
- AppKit owns every control, and the web view gains none. Yellow means Claude: the banner dot and the running button use theme.css `--c-changed`, `#C79A2E` light and `#D8B25C` dark.
- Copy is verbatim from spec §5 and §9, and lives only in `SessionCopy`.
- Match the codebase voice: doc comments explain *why*, in full sentences.
- Byte fidelity: Undo and Redo write exact bytes and never re-encode.
- Tests use the custom harness (`T.suite`, `T.ok`, `T.eq`, `T.skip`), with suites registered in `CrookTests/main.swift`. Tests never launch Terminal, never run the real `claude`, and never open a network connection.

---

## File Structure

New files, `Crook/Claude/`:

| File | Responsibility |
|---|---|
| `SessionPlan.swift` | Pure. Working folder, relative path, session name, first message, system prompt, pre-approval rule, argv, and selection-to-lines. |
| `SessionRunner.swift` | Pure. The outcome enum, exit parsing, the outcome mapping, NUL payload encoding, the remote command template, and the static local runner, remote runner and window AppleScript. |
| `TerminalLauncher.swift` | Writes a session folder, opens it with Terminal, computes placement (pure), and reads a window frame back from the window server. |
| `ClaudePreflight.swift` | Finds Claude Code and its version on this Mac (known locations, then login shell) or over ssh. Parses and compares versions. |
| `SessionRegistry.swift` | `ClaudeSession` (record, state, folder) and `SessionRegistry`: begin, watch for start and exit, End Session, discard, reattach after restart. |
| `SessionReview.swift` | Pure. Precise changed lines, tally, byte-exact replace, protected folder name. |
| `SessionCopy.swift` | `BannerContent`, banner facts to banner, availability, and alert copy. Every string. |
| `SessionBanner.swift` | The AppKit banner view. |
| `ClaudeButton.swift` | The title bar accessory button and its states. |
| `AskPopover.swift` | The popover. |
| `SessionController.swift` | Window glue: button, popover, checks, launch, watch mode, banners, end handling, review, Undo and Redo, placement, menus. |

New test files, `CrookTests/`: `ClaudePlanTests.swift`, `ClaudeRunnerTests.swift` (runner, outcomes, placement), `ClaudePreflightTests.swift`, `ClaudeRegistryTests.swift`, `ClaudeReviewTests.swift`.

Modified files:
- `Crook/Remote/SSHTransport.swift`: `static connectionOptions`, `runCommand`.
- `web/src/editor.js`: read-only compartment, attempt reporting, `revealLine`.
- `Crook/Editor/EditorBridge.swift`: `setReadOnly`, `revealLine`, `selection`, `onReadOnlyAttempt`.
- `Crook/Editor/EditorViewController.swift`: banner host, `setBanner`, `pulseBanner`, `showDiff(since:)`.
- `Crook/Editor/DiffOverlay.swift`: `since:` wording.
- `Crook/WorkspaceWindowController.swift`: owns `SessionController`, change hooks, menu actions.
- `Crook/CrookDocument.swift`: `saveBeforeSession()`, and edit notification.
- `Crook/Workspace/Workspace.swift`: `filePaths(under:)`, and suggestions skip `~/.claude`.
- `Crook/Workspace/RailViewController.swift`: the session sparkle on a row.
- `Crook/AppDelegate.swift`: menu items, and reattach at launch.
- `CrookTests/main.swift`: suite dispatch.
- `README.md`, `scripts/build.sh` (version 0.3.0).

---

### Task 1: SessionPlan — what Claude Code is told

**Files:**
- Create: `Crook/Claude/SessionPlan.swift`
- Create: `CrookTests/ClaudePlanTests.swift`
- Modify: `CrookTests/main.swift` (add dispatch line)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct SessionPlan: Equatable` with fields `workingDirectory`, `relativePath`, `sessionName`, `firstMessage`, `systemPrompt: String`, `preapprovalRule: String?` and `arguments: [String]`.
  - `SessionPlan.Input(filePath:projectRoots:home:machineName:selectedLines:request:voiceOver:sessionID:)`.
  - Statics: `make(_:) -> SessionPlan`, `workingDirectory(for:roots:home:) -> String`, `relativePath(_:from:) -> String`, `sessionName(file:machine:) -> String`, `firstMessage(relativePath:lines:request:) -> String`, `systemPrompt(file:lines:) -> String`, `preapprovalRule(for:) -> String?`, `selectedLines(in: NSString, anchor: Int, head: Int) -> ClosedRange<Int>?`, `linesPhrase(_:) -> String`.

- [ ] **Step 1: Write the failing test**

<!-- write: CrookTests/ClaudePlanTests.swift -->
```swift
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
             SessionPlan.preapprovalRule(for: "/Users/alice/.claude/CLAUDE.md"),
             "Edit(//Users/alice/.claude/CLAUDE.md)")
        T.ok("CP-17  a path that would read as a glob gets no rule",
             SessionPlan.preapprovalRule(for: "/Users/alice/notes [old]/CLAUDE.md") == nil
             && SessionPlan.preapprovalRule(for: "/Users/alice/a*b/CLAUDE.md") == nil)

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
        T.ok("CP-20  the rule follows --allowedTools",
             pairs.contains { $0 == "--allowedTools" && $1 == "Edit(//Users/alice/.claude/skills/release-notes/SKILL.md)" })
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
```

In `CrookTests/main.swift`, add after the `regress` line:

```swift
if want("claude-plan") { ClaudePlanTests.run() }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh claude-plan`
Expected: compile error "cannot find 'SessionPlan' in scope".

- [ ] **Step 3: Write the implementation**

<!-- write: Crook/Claude/SessionPlan.swift -->
```swift
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test.sh claude-plan`
Expected: all CP-01 to CP-29 `ok`, and "0 failed".

- [ ] **Step 5: Commit**

```bash
git add Crook/Claude/SessionPlan.swift CrookTests/ClaudePlanTests.swift CrookTests/main.swift
git commit -m "Decide what Claude Code is told, without Terminal"
```

---

### Task 2: The runner, the launcher and placement

**Files:**
- Create: `Crook/Claude/SessionRunner.swift`
- Create: `Crook/Claude/TerminalLauncher.swift`
- Create: `CrookTests/ClaudeRunnerTests.swift`
- Modify: `Crook/Remote/SSHTransport.swift:80-90` (`commonOptions` becomes `static connectionOptions`)
- Modify: `CrookTests/main.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `SessionRunner.Outcome: String, Codable`, with cases `finished`, `claudeMissing`, `folderMissing`, `folderAccess`, `couldNotConnect`, `connectionLost`, `closedWithoutChanges`, `stoppedUnexpectedly`, `didNotStart`.
  - `SessionRunner.Exit(status: Int32, seconds: Int)`.
  - `SessionRunner.parseExit(_:) -> Exit?` and `outcome(exit:endRequested:isRemote:fileChanged:) -> Outcome`.
  - `SessionRunner.encodeFields(_:) -> Data`, `remoteCommand(workingDirectory:arguments:) -> String`.
  - Static script strings: `localScript`, `remoteScript`, `windowScript`, `resolveClaude`.
  - `TerminalLauncher.Command` with cases `.local(workingDirectory:claudePath:)` and `.remote(host:workingDirectory:)`.
  - `TerminalLauncher.prepare(folder:command:claudeArguments:bounds:bundleID:includeWindowScript:sshPath:) throws` and `open(folder:completion:)`.
  - `TerminalLauncher.Placement(terminal: CGRect, crook: CGRect?)`, `placement(crook:visible:primaryHeight:crookMinWidth:terminalMin:terminalMax:)`, `frameOfWindow(number:) -> CGRect?`, `landed(_:near:tolerance:) -> Bool`, and `terminalBundleID`.
  - `SSHTransport.connectionOptions: [String]` (static).

- [ ] **Step 1: Write the failing tests**

<!-- write: CrookTests/ClaudeRunnerTests.swift -->
```swift
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
            install(shell, "#!/bin/sh\nprintf '%s\\n' \"$CROOK_STUB_CLAUDE\"\n")
        }

        private func install(_ url: URL, _ text: String) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func environment(stubOnPath: Bool = true, claudeOnFarMac: String? = nil, exit: Int32 = 0) -> [String: String] {
            [
                "HOME": dir.path,
                "PATH": (stubOnPath ? bin.path + ":" : "") + "/usr/bin:/bin:/usr/sbin:/sbin",
                "SHELL": shell.path,
                "CROOK_STUB_OUT": out.path,
                "CROOK_STUB_EXIT": String(exit),
                "CROOK_STUB_CLAUDE": claudeOnFarMac ?? claude.path,
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
                                         bounds: nil, bundleID: nil, includeWindowScript: false,
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
        T.eq("CR-01  the runner reports a clean exit", runRunner(local, bench.environment())?.status, 0)
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
        T.eq("CR-07  a 100 KB request survives, through the fallback path", bench.args(), bigArgs)

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
        T.ok("CR-13  ssh gets a terminal, Crook's own connection options, and the host",
             ssh.first == "-t"
             && Array(ssh.dropFirst().prefix(optionCount)) == SSHTransport.connectionOptions
             && ssh.count == optionCount + 3 && ssh[optionCount + 1] == "mac-mini",
             ssh.dropLast().joined(separator: " | "))
        T.ok("CR-14  the remote command is a fixed template with nothing of the request in it",
             (ssh.last ?? "").hasPrefix("/bin/sh -c 'exec /bin/zsh -c ") && !(ssh.last ?? "").contains("quoted"))
        T.eq("CR-15  claude on the far Mac starts in the working folder", bench.cwd(), project.path)
        T.eq("CR-16  and receives every argument byte for byte", bench.args(), args)
        T.ok("CR-17  and nothing in them ran as code there either", !fm.fileExists(atPath: pwned.path))

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
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)   // 14-inch MacBook Pro, less the menu bar
        let primary: CGFloat = 982
        let roomy = TerminalLauncher.placement(crook: CGRect(x: 40, y: 100, width: 800, height: 700),
                                               visible: visible, primaryHeight: primary)
        T.ok("CL-01  room on the right: Terminal goes there and Crook stays put",
             roomy.crook == nil && roomy.terminal == CGRect(x: 840, y: 182, width: 672, height: 700), "\(roomy)")
        let rightHeavy = TerminalLauncher.placement(crook: CGRect(x: 700, y: 100, width: 800, height: 700),
                                                    visible: visible, primaryHeight: primary)
        T.ok("CL-02  room only on the left: Terminal goes there instead",
             rightHeavy.crook == nil && rightHeavy.terminal.maxX == 700 && rightHeavy.terminal.width == 700, "\(rightHeavy)")
        let wide = TerminalLauncher.placement(crook: CGRect(x: 100, y: 50, width: 1300, height: 850),
                                              visible: visible, primaryHeight: primary)
        T.ok("CL-03  no room: Crook moves to the left edge and narrows only as far as it must",
             wide.crook == CGRect(x: 0, y: 50, width: 952, height: 850), "\(wide)")
        T.ok("CL-04  and Terminal takes the rest",
             wide.terminal == CGRect(x: 952, y: 82, width: 560, height: 850), "\(wide)")
        let tiny = TerminalLauncher.placement(crook: CGRect(x: 0, y: 0, width: 1100, height: 700),
                                              visible: CGRect(x: 0, y: 0, width: 1200, height: 760),
                                              primaryHeight: 800, crookMinWidth: 720)
        T.ok("CL-05  never narrower than Crook's minimum, overlapping on a screen that small",
             tiny.crook?.width == 720 && tiny.terminal.width == 560 && tiny.terminal.maxX == 1200, "\(tiny)")
        let second = TerminalLauncher.placement(crook: CGRect(x: -3000, y: 200, width: 1200, height: 900),
                                                visible: CGRect(x: -3440, y: 17, width: 3440, height: 1377),
                                                primaryHeight: primary)
        T.ok("CL-06  on a display left of the main one, coordinates stay global",
             second.crook == nil && second.terminal.minX == -1800 && second.terminal.minY == -118, "\(second)")
        T.ok("CL-07  landing within a few points counts; landing somewhere else does not",
             TerminalLauncher.landed(CGRect(x: 845, y: 190, width: 680, height: 690), near: roomy.terminal)
             && !TerminalLauncher.landed(CGRect(x: 845, y: 33, width: 680, height: 690), near: roomy.terminal)
             && !TerminalLauncher.landed(nil, near: roomy.terminal))
    }
}
```

In `CrookTests/main.swift` add:

```swift
if want("claude-runner") { ClaudeRunnerTests.run() }
if want("claude-exit") { ClaudeRunnerTests.outcomes() }
if want("claude-placement") { ClaudeRunnerTests.placement() }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh claude-runner claude-exit claude-placement`
Expected: compile errors for `SessionRunner`, `TerminalLauncher` and `SSHTransport.connectionOptions`.

- [ ] **Step 3: Share ssh's options**

In `Crook/Remote/SSHTransport.swift`, replace:

```swift
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
```

with:

```swift
    ///
    /// Static, because Edit with Claude runs ssh too — inside a Terminal
    /// window — and it has to join this same connection. A copy of these
    /// options that drifted would stop sharing it and silently cost the person
    /// a second password.
    static var connectionOptions: [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=10m",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
    }

    private var commonOptions: [String] { Self.connectionOptions }
```

(The existing doc comment above `commonOptions` stays. The new lines continue it.)

- [ ] **Step 4: Write SessionRunner**

<!-- write: Crook/Claude/SessionRunner.swift -->
```swift
import Foundation

/// The scripts that run a session, and what their exit means.
///
/// Two rules shape all of it. The scripts are static — the same text for every
/// session — and read everything specific from files beside them. And no text
/// that came from a file name, a path, a machine or a person's request is ever
/// placed into shell source: it travels NUL-separated and reaches the program
/// as arguments. Quoting is where launchers like this break, and the way not to
/// get quoting wrong is not to do any.
enum SessionRunner {

    enum Outcome: String, Codable, Equatable {
        case finished
        case claudeMissing
        case folderMissing
        case folderAccess
        case couldNotConnect
        case connectionLost
        case closedWithoutChanges
        case stoppedUnexpectedly
        case didNotStart
    }

    struct Exit: Equatable {
        let status: Int32
        let seconds: Int
    }

    /// The runners' own failures, clear of anything Claude Code or ssh exits with.
    static let claudeMissingStatus: Int32 = 90
    static let folderMissingStatus: Int32 = 91
    static let folderAccessStatus: Int32 = 92

    /// `exit` holds "status seconds".
    static func parseExit(_ text: String) -> Exit? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let status = Int32(parts[0]), let seconds = Int(parts[1]) else { return nil }
        return Exit(status: status, seconds: seconds)
    }

    /// What the person is told, from how the session ended.
    ///
    /// `exit` is nil when the runner wrote none: closing the Terminal window
    /// takes the runner with it. That is someone ending their own session, not
    /// a failure.
    static func outcome(exit: Exit?, endRequested: Bool, isRemote: Bool, fileChanged: Bool) -> Outcome {
        if endRequested { return .finished }
        guard let exit else { return .finished }
        switch exit.status {
        case 0, 130: return .finished
        case claudeMissingStatus: return .claudeMissing
        case folderMissingStatus: return .folderMissing
        case folderAccessStatus: return .folderAccess
        case 255 where isRemote: return exit.seconds < 10 ? .couldNotConnect : .connectionLost
        default:
            // Declining Claude Code's trust question exits 1 before anything
            // changed, and so does an error at startup. Both get the sentence
            // that suggests trying again; neither "stopped unexpectedly".
            return fileChanged ? .stoppedUnexpectedly : .closedWithoutChanges
        }
    }

    // MARK: - data, never code

    /// Fields separated by NUL, which cannot occur in a path or an argument.
    static func encodeFields(_ fields: [String]) -> Data {
        var d = Data()
        for f in fields {
            d.append(contentsOf: Array(f.replacingOccurrences(of: "\u{0}", with: "").utf8))
            d.append(0)
        }
        // Command substitution drops trailing newlines, which would clip the
        // last real field. A sentinel field takes that loss instead.
        d.append(UInt8(ascii: "."))
        return d
    }

    /// The command ssh runs on the other Mac.
    ///
    /// A fixed template holding two base64 tokens, whose alphabet has no quote,
    /// space or `$`. `/bin/sh -c '…'` makes it parse the same whether that
    /// Mac's login shell is zsh, bash, fish or tcsh. The decoded script is
    /// static; the payload is only ever data.
    static func remoteCommand(workingDirectory: String, arguments: [String]) -> String {
        let script = Data(remoteScript.utf8).base64EncodedString()
        let payload = encodeFields([workingDirectory] + arguments).base64EncodedString()
        return "/bin/sh -c 'exec /bin/zsh -c \"$(printf %s \(script) | /usr/bin/base64 -D)\" crook \(payload)'"
    }

    // MARK: - scripts

    /// Finds `claude` the way the person's own shell would — a login,
    /// interactive one, since installers add to PATH in .zshrc — then where the
    /// installers put it. An alias or a function is not a path and falls
    /// through to the known locations.
    static let resolveClaude = #"""
    crook_resolve_claude() {
      local exe c
      exe=$(/usr/bin/perl -e 'alarm 8; exec @ARGV' "${SHELL:-/bin/zsh}" -lic 'command -v claude' </dev/null 2>/dev/null | /usr/bin/tail -n 1)
      exe=${exe//$'\r'/}
      if [[ $exe != /* || ! -x $exe ]]; then
        exe=""
        for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.claude/local/claude"; do
          if [[ -x $c ]]; then exe=$c; break; fi
        done
      fi
      print -r -- "$exe"
    }

    """#

    /// Runs on the other Mac as `zsh -c <this> crook <payload>`.
    static let remoteScript = "emulate -R zsh\n" + resolveClaude + #"""
    typeset -a f
    f=("${(@0)"$(print -rn -- "$1" | /usr/bin/base64 -D)"}")
    f[-1]=()
    dir=$f[1]
    shift f
    cd -- "$dir" 2>/dev/null || exit 91
    exe=$(crook_resolve_claude)
    [[ -n $exe ]] || exit 90
    exec "$exe" "${f[@]}"

    """#

    /// launch.command, which Terminal runs.
    static let localScript = #"""
    #!/bin/zsh
    # Crook: one Edit with Claude session.
    #
    # The same text for every session. Everything about this one is read from
    # the files beside it, and nothing read from them is run as shell code:
    # arguments arrive NUL-separated and are handed to the program as arguments.
    emulate -R zsh
    S=${0:A:h}
    cd -- "$S" || exit 1
    # Crook gave up waiting for this window (or the session was discarded):
    # starting Claude now would be a session nobody is watching.
    [[ -e abandoned ]] && exit 0
    print -r -- $$ > runner.pid.tmp && mv -f runner.pid.tmp runner.pid
    # Claude Code reads Ctrl-C as a key. Should one reach this script anyway,
    # carry on so the ending is still reported. A handler, not an ignore: an
    # ignored signal would stay ignored in the program run below.
    trap : INT

    # This window, so it can be placed beside Crook and closed at the end.
    W=""
    if [[ -f window.applescript ]]; then
      W=$(/usr/bin/osascript window.applescript find "$(tty)" 2>/dev/null)
      [[ $W == <-> ]] || W=""
      print -r -- "$W" > window
      if [[ -n $W && -s bounds ]]; then
        /usr/bin/osascript window.applescript place "$W" ${(s: :)"$(<bounds)"} >/dev/null 2>&1
      fi
    fi

    typeset -a cmd
    cmd=("${(@0)"$(<argv)"}")
    cmd[-1]=()
    started=$SECONDS
    st=0

    run_child() {
      print -n $'\e[2J\e[H'
      /bin/zsh -fc 'print -r -- $$ > "$1/child.pid"; shift; exec "$@"' crook "$S" "$@"
    }

    if [[ $(<mode) == local ]]; then
      if ! cd -- "$(<cwd)" 2>/dev/null; then
        st=91
      elif ! /bin/ls -- . >/dev/null 2>&1; then
        st=92
      else
        exe=$(whence -p claude)
        [[ -x $exe ]] || exe=$cmd[1]
        if [[ -x $exe ]]; then
          run_child "$exe" "${(@)cmd[2,-1]}"
          st=$?
        else
          st=90
        fi
      fi
    else
      run_child "${(@)cmd}"
      st=$?
    fi

    cd -- "$S"
    print -r -- "$st $(( SECONDS - started ))" > exit.tmp && mv -f exit.tmp exit

    close_window() {
      [[ -n $W ]] || return 0
      /usr/bin/perl -MPOSIX -e 'setsid(); exec @ARGV' /usr/bin/osascript "$S/window.applescript" close-when-idle "$W" </dev/null >/dev/null 2>&1 &!
    }
    bring_crook_forward() {
      [[ -s bundle ]] && /usr/bin/open -b "$(<bundle)" >/dev/null 2>&1
    }

    if [[ -e end-requested ]]; then
      close_window
    elif (( st == 0 || st == 130 || (st >= 90 && st <= 92) )); then
      bring_crook_forward
      close_window
    elif [[ -s bundle ]]; then
      # A session Crook is watching: say where the explanation is. (Update in
      # Terminal has no bundle file, and its own output says what happened.)
      print
      print -r -- "Claude Code stopped. Crook has the details, and you can close this window."
    fi
    exit 0

    """#

    /// Crook's handle on the Terminal window its runner is in. Run from inside
    /// that window, so Terminal only ever talks about itself and macOS asks
    /// nobody for permission (check S2, S3). A window holding more than one tab
    /// belongs to the person, not the runner, and is left alone.
    static let windowScript = #"""
    on run argv
    	set verb to item 1 of argv
    	tell application "Terminal"
    		if verb is "find" then
    			set target to item 2 of argv
    			repeat with w in windows
    				if (count of tabs of w) is 1 then
    					set t to tab 1 of w
    					if ((tty of t) as text) is target and (busy of t) then return (id of w) as text
    				end if
    			end repeat
    			return ""
    		else if verb is "place" then
    			set bounds of window id ((item 2 of argv) as integer) to {(item 3 of argv) as integer, (item 4 of argv) as integer, (item 5 of argv) as integer, (item 6 of argv) as integer}
    		else if verb is "close-when-idle" then
    			set w to window id ((item 2 of argv) as integer)
    			repeat 100 times
    				if not (busy of tab 1 of w) then exit repeat
    				delay 0.1
    			end repeat
    			if (count of tabs of w) is 1 then close w
    		end if
    	end tell
    	return ""
    end run

    """#
}
```

- [ ] **Step 5: Write TerminalLauncher**

<!-- write: Crook/Claude/TerminalLauncher.swift -->
```swift
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
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test.sh claude-runner claude-exit claude-placement agent`
Expected: CR, CX and CL all `ok`, and `agent` still passes (the `commonOptions` refactor). "0 failed".

- [ ] **Step 7: Commit**

```bash
git add Crook/Claude/SessionRunner.swift Crook/Claude/TerminalLauncher.swift Crook/Remote/SSHTransport.swift CrookTests/ClaudeRunnerTests.swift CrookTests/main.swift
git commit -m "Run a session from static scripts, with nothing quoted"
```

---

### Task 3: ClaudePreflight — is Claude Code there?

**Files:**
- Create: `Crook/Claude/ClaudePreflight.swift`
- Create: `CrookTests/ClaudePreflightTests.swift`
- Modify: `Crook/Remote/SSHTransport.swift` (add `runCommand`)
- Modify: `CrookTests/main.swift`

**Interfaces:**
- Consumes: `SessionRunner.resolveClaude` (Task 2).
- Produces:
  - `ClaudePreflight.Result`, with cases `.ready(path: String, version: String)`, `.missing` and `.tooOld(version: String)`.
  - `minimumVersion`.
  - `knownLocations(home:) -> [String]`, `version(from:) -> String?`, `isAtLeast(_:_:) -> Bool` and `judge(path:versionOutput:) -> Result`.
  - `checkLocal(home:loginShell:) -> Result`, `forgetCachedInstall()` and `loginShell() -> String`.
  - `remoteScript`, `remoteCommand() -> String`, `parseRemote(_:) -> Result` and `checkRemote(_ transport: SSHTransport) -> Result?`.
  - `SSHTransport.runCommand(_:timeout:) -> (status: Int32, out: String, err: String)`.

- [ ] **Step 1: Write the failing test**

<!-- write: CrookTests/ClaudePreflightTests.swift -->
```swift
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
        if ClaudePreflight.knownLocations(home: home.path).contains(where: { fm.isExecutableFile(atPath: $0) }) {
            T.skip("CF-09  nothing anywhere is missing", "Claude Code is installed system-wide on this machine")
            T.skip("CF-10  a login shell that hangs is given up on", "Claude Code is installed system-wide on this machine")
        } else {
            T.eq("CF-09  nothing anywhere is missing",
                 ClaudePreflight.checkLocal(home: home.path, loginShell: silentShell.path), .missing)
            let hanging = script("hanging-shell", "#!/bin/sh\nsleep 30\n")
            let started = Date()
            ClaudePreflight.forgetCachedInstall()
            _ = ClaudePreflight.checkLocal(home: home.path, loginShell: hanging.path)
            let took = Date().timeIntervalSince(started)
            T.ok("CF-10  a login shell that hangs is given up on", took < 6, String(format: "%.1f s", took))
        }

        T.suite("claude-preflight — another Mac")
        T.eq("CF-11  a path and a version",
             ClaudePreflight.parseRemote("/Users/max/.local/bin/claude\n2.1.300 (Claude Code)\n"),
             .ready(path: "/Users/max/.local/bin/claude", version: "2.1.300"))
        T.eq("CF-12  an empty first line is missing", ClaudePreflight.parseRemote("\n"), .missing)

        // The real remote command, run here through /bin/sh the way a login
        // shell on the far Mac runs what ssh hands it.
        fakeClaude("2.4.0")
        let farShell = script("far-shell", "#!/bin/sh\necho \(installed)\n")
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
```

In `CrookTests/main.swift` add:

```swift
if want("claude-preflight") { ClaudePreflightTests.run() }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh claude-preflight`
Expected: compile error "cannot find 'ClaudePreflight' in scope".

- [ ] **Step 3: Add a one-shot command to SSHTransport**

In `Crook/Remote/SSHTransport.swift`, directly after `func disconnect() { … }`, add:

```swift
    /// One command on the far Mac, over the shared connection.
    ///
    /// Never prompts: if the connection has gone, this fails rather than ask
    /// ssh for a password nobody can see. Blocks; call it off the main thread.
    func runCommand(_ command: String, timeout: TimeInterval) -> (status: Int32, out: String, err: String) {
        let r = run([host, command], secret: nil, timeout: timeout)
        return (r.status, String(data: r.out, encoding: .utf8) ?? "", r.err)
    }
```

- [ ] **Step 4: Write ClaudePreflight**

<!-- write: Crook/Claude/ClaudePreflight.swift -->
```swift
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
        [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         home + "/.claude/local/claude"]
    }

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
        let result = judge(path: path, versionOutput: run(path, ["--version"], timeout: 8))
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

    /// Prints the path on one line and `claude --version` after it.
    static let remoteScript = "emulate -R zsh\n" + SessionRunner.resolveClaude + #"""
    exe=$(crook_resolve_claude)
    print -r -- "$exe"
    if [[ -n $exe ]]; then
      /usr/bin/perl -e 'alarm 10; exec @ARGV' "$exe" --version 2>/dev/null
    fi
    exit 0

    """#

    /// The same fixed template the runner uses, so nothing is quoted here either.
    static func remoteCommand() -> String {
        let script = Data(remoteScript.utf8).base64EncodedString()
        return "/bin/sh -c 'exec /bin/zsh -c \"$(printf %s \(script) | /usr/bin/base64 -D)\"'"
    }

    static func parseRemote(_ output: String) -> Result {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), first.hasPrefix("/")
        else { return .missing }
        return judge(path: first, versionOutput: lines.dropFirst().joined(separator: "\n"))
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test.sh claude-preflight`
Expected: CF-01 to CF-13 `ok`, or skipped where Claude Code is installed system-wide. "0 failed".

- [ ] **Step 6: Commit**

```bash
git add Crook/Claude/ClaudePreflight.swift Crook/Remote/SSHTransport.swift CrookTests/ClaudePreflightTests.swift CrookTests/main.swift
git commit -m "Find Claude Code before opening Terminal, on either Mac"
```

---

### Task 4: SessionRegistry — what is running, across restarts

**Files:**
- Create: `Crook/Claude/SessionRegistry.swift`
- Create: `CrookTests/ClaudeRegistryTests.swift`
- Modify: `CrookTests/main.swift`

**Interfaces:**
- Consumes: `SessionRunner.Outcome`, `SessionRunner.parseExit`, `SessionRunner.outcome(...)` (Task 2), and `Providers.local.id`.
- Produces:
  - `final class ClaudeSession`, with `State` cases `.opening`, `.running`, `.stopping`, `.ended(Outcome)` and `.restored(Outcome)`.
  - `Record: Codable`, with fields `id`, `filePath`, `providerID`, `machineName`, `workingDirectory`, `startedAt`, `runnerPID`, `crookFrameBefore`, `crookFrameSet`, `endRequested`, `outcome`, `endedAt`, `restored`, `fingerprintsAtStart` and `alsoChanged`.
  - Properties `folder`, `record`, `state`, `fileVanished`, `handledStart`, `endedWhileAway`, `id`, `isRemote`, `isLive`, `outcome`, `baseline` and `finalBytes`, plus `file(_:) -> URL`.
  - `final class SessionRegistry`, with `shared` and `init(root:)`.
  - Registry properties: `root`, `sessions`, `onChange`, `fileChanged`.
  - Registry methods: `begin(id:filePath:providerID:machineName:workingDirectory:baseline:) throws -> ClaudeSession`, `save(_:)`, `session(for:providerID:)`, `liveSession(for:providerID:)`, `watch(_:startTimeout:)`, `requestEnd(_:)`, `discard(_:)` and `reattach(now:)`.
  - Registry statics: `readPID(_:)`, `isRunner(pid:of:)`, `arguments(of:)`.

- [ ] **Step 1: Write the failing test**

<!-- write: CrookTests/ClaudeRegistryTests.swift -->
```swift
import Foundation

/// Knowing what is running — across a Crook restart, and without mistaking a
/// stranger's process for a session.
///
/// Stand-in runners play Terminal's part: a tiny zsh script in the session
/// folder that reports its PID, maybe starts a child, and exits. The registry
/// cannot tell them from the real one, which is the point.
enum ClaudeRegistryTests {

    private static let fm = FileManager.default

    private static func spin(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    @discardableResult
    private static func startRunner(_ s: ClaudeSession, _ body: String) -> Process {
        let url = s.file("launch.command")
        try? ("#!/bin/zsh\ncd -- \"${0:A:h}\"\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return p
    }

    private static func begin(_ r: SessionRegistry, _ path: String, baseline: Data = Data()) -> ClaudeSession? {
        try? r.begin(filePath: path, providerID: "local", machineName: nil,
                     workingDirectory: (path as NSString).deletingLastPathComponent, baseline: baseline)
    }

    static func run() {
        T.suite("claude-registry — a session's life")
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crook-sessions-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let registry = SessionRegistry(root: root)
        var seen: [ClaudeSession.State] = []
        registry.onChange = { seen.append($0.state) }
        registry.fileChanged = { _ in false }

        guard let s = begin(registry, "/Users/alice/.claude/CLAUDE.md", baseline: Data("# hi\r\n".utf8)) else {
            T.ok("CG-01  a session begins", false); return
        }
        T.ok("CG-01  a session begins with its exact baseline and its record on disk",
             s.baseline == Data("# hi\r\n".utf8) && fm.fileExists(atPath: s.file("session.json").path))
        T.eq("CG-02  its folder is private",
             (try? fm.attributesOfItem(atPath: s.folder.path))?[.posixPermissions] as? Int, 0o700)
        T.ok("CG-03  it is found by file and machine",
             registry.session(for: "/Users/alice/.claude/CLAUDE.md", providerID: "local") === s)
        T.ok("CG-04  and not by the same path on another machine",
             registry.session(for: "/Users/alice/.claude/CLAUDE.md", providerID: "ssh:mini") == nil)

        registry.watch(s)
        startRunner(s, "print -r -- $$ > runner.pid\nsleep 0.6\nprint -r -- '0 1' > exit\n")
        T.ok("CG-05  the runner reporting in makes it running", spin(5) { s.state == .running })
        T.ok("CG-06  and its exit makes it finished", spin(5) { s.state == .ended(.finished) }, "\(s.state)")
        T.ok("CG-07  both changes were announced", seen.contains(.running) && seen.last == .ended(.finished))

        T.suite("claude-registry — ending one")
        guard let e = begin(registry, "/tmp/e.md") else { return }
        registry.watch(e)
        startRunner(e, """
        print -r -- $$ > runner.pid
        /bin/zsh -fc 'print -r -- $$ > child.pid; exec sleep 30'
        print -r -- "$? 0" > exit
        """)
        _ = spin(5) { e.state == .running && fm.fileExists(atPath: e.file("child.pid").path) }
        let asked = Date()
        registry.requestEnd(e)
        T.ok("CG-08  End Session stops it promptly, and it counts as finished",
             spin(6) { e.state == .ended(.finished) } && Date().timeIntervalSince(asked) < 5, "\(e.state)")
        T.ok("CG-09  the runner was told, so it can close its window", fm.fileExists(atPath: e.file("end-requested").path))

        guard let stubborn = begin(registry, "/tmp/stubborn.md") else { return }
        registry.watch(stubborn)
        startRunner(stubborn, """
        print -r -- $$ > runner.pid
        /bin/zsh -fc 'print -r -- $$ > child.pid; trap "" TERM; while true; do sleep 1; done'
        print -r -- "$? 0" > exit
        """)
        _ = spin(5) { stubborn.state == .running && fm.fileExists(atPath: stubborn.file("child.pid").path) }
        registry.requestEnd(stubborn)
        T.ok("CG-10  a program that ignores SIGTERM is killed three seconds later",
             spin(8) { stubborn.state == .ended(.finished) }, "\(stubborn.state)")

        guard let never = begin(registry, "/tmp/never.md") else { return }
        registry.watch(never, startTimeout: 0.5)
        T.ok("CG-11  no report from the runner in time is didNotStart", spin(3) { never.state == .ended(.didNotStart) })
        T.ok("CG-12  and a runner that turns up late is told to stand down",
             fm.fileExists(atPath: never.file("abandoned").path))

        registry.discard(s)
        T.ok("CG-13  Done forgets a session, folder and all",
             !fm.fileExists(atPath: s.folder.path)
             && registry.session(for: "/Users/alice/.claude/CLAUDE.md", providerID: "local") == nil)

        T.suite("claude-registry — after Crook restarts")
        guard let live = begin(registry, "/tmp/live.md"),
              let ended = begin(registry, "/tmp/ended.md"),
              let old = begin(registry, "/tmp/old.md"),
              let imposter = begin(registry, "/tmp/imposter.md") else { return }
        registry.watch(live)
        let liveRunner = startRunner(live, "print -r -- $$ > runner.pid\nsleep 20\nprint -r -- '0 20' > exit\n")
        _ = spin(5) { live.state == .running }
        ended.record.outcome = .finished
        ended.record.endedAt = Date()
        registry.save(ended)
        old.record.outcome = .finished
        old.record.endedAt = Date().addingTimeInterval(-8 * 86_400)
        registry.save(old)
        imposter.record.runnerPID = getpid()   // alive, but nobody's runner
        registry.save(imposter)
        let stray = root.appendingPathComponent("update-1234", isDirectory: true)
        try? fm.createDirectory(at: stray, withIntermediateDirectories: true)

        let again = SessionRegistry(root: root)
        again.fileChanged = { _ in false }
        again.reattach()
        let back = again.session(for: "/tmp/live.md", providerID: "local")
        T.ok("CG-14  a session still running is running again", back?.state == .running, "\(String(describing: back?.state))")
        T.ok("CG-15  one that ended and was never dismissed still waits for Done",
             again.session(for: "/tmp/ended.md", providerID: "local")?.state == .ended(.finished))
        T.ok("CG-16  one that ended over a week ago is gone",
             again.session(for: "/tmp/old.md", providerID: "local") == nil && !fm.fileExists(atPath: old.folder.path))
        let imp = again.session(for: "/tmp/imposter.md", providerID: "local")
        T.ok("CG-17  a live process that is not this session's runner is not mistaken for it",
             imp != nil && imp?.isLive == false, "\(String(describing: imp?.state))")
        T.ok("CG-18  a folder that is not a session is cleared away", !fm.fileExists(atPath: stray.path))
        liveRunner.terminate()
        T.ok("CG-19  the reattached session still notices its runner exit", spin(5) { back?.isLive == false })
    }
}
```

In `CrookTests/main.swift` add:

```swift
if want("claude-registry") { ClaudeRegistryTests.run() }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh claude-registry`
Expected: compile error "cannot find 'SessionRegistry' in scope".

- [ ] **Step 3: Write the implementation**

<!-- write: Crook/Claude/SessionRegistry.swift -->
```swift
import Foundation
import Darwin

/// One Edit with Claude session: the file, the machine, the folder its runner
/// reads, and what has happened so far.
///
/// The session itself belongs to Terminal. This is Crook's record of it —
/// enough, in session.json, to pick it up again after Crook quits.
final class ClaudeSession {

    enum State: Equatable {
        case opening
        case running
        case stopping
        case ended(SessionRunner.Outcome)
        /// After Undo. Redo goes back to `ended`.
        case restored(SessionRunner.Outcome)
    }

    struct Record: Codable, Equatable {
        var id: UUID
        var filePath: String
        var providerID: String
        var machineName: String?
        var workingDirectory: String
        var startedAt: Date
        var runnerPID: Int32?
        var crookFrameBefore: CGRect?
        var crookFrameSet: CGRect?
        var endRequested = false
        var outcome: SessionRunner.Outcome?
        var endedAt: Date?
        var restored = false
        /// Fingerprints of the other files near this one as the session began.
        var fingerprintsAtStart: [String: String] = [:]
        /// Absolute paths of the files near this one that changed during it.
        var alsoChanged: [String] = []
    }

    let folder: URL
    var record: Record
    var state: State
    /// The file went away while the session ran, or by the time it ended.
    var fileVanished = false
    /// Placement and first-run bookkeeping have been done for this session.
    var handledStart = false
    /// Found already over when Crook launched: its failures are old news.
    var endedWhileAway = false

    init(folder: URL, record: Record, state: State) {
        self.folder = folder
        self.record = record
        self.state = state
    }

    var id: UUID { record.id }
    var isRemote: Bool { record.providerID != Providers.local.id }

    var isLive: Bool {
        switch state {
        case .opening, .running, .stopping: return true
        case .ended, .restored: return false
        }
    }

    var outcome: SessionRunner.Outcome? {
        switch state {
        case .ended(let o), .restored(let o): return o
        default: return nil
        }
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// The file's exact bytes when the session began: what Undo puts back.
    var baseline: Data? { try? Data(contentsOf: file("baseline")) }
    /// The file's exact bytes when it ended: what Redo puts back.
    var finalBytes: Data? { try? Data(contentsOf: file("final")) }
}

/// Every session Crook knows about, and the processes behind them.
///
/// A start is noticed when the runner writes its PID; an end when that process
/// exits, through a kqueue process source. That works for any process this
/// user owns, not only Crook's own children — which is what lets a session
/// outlive Crook and be picked up again.
final class SessionRegistry {

    static let shared = SessionRegistry()

    /// Disposable state, outside every project, in a path with no spaces.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crook/sessions", isDirectory: true)
    }

    let root: URL
    private(set) var sessions: [ClaudeSession] = []
    /// On the main queue, after any session's state changes.
    var onChange: ((ClaudeSession) -> Void)?
    /// Whether a session's file differs from its baseline; asked as it ends.
    var fileChanged: ((ClaudeSession) -> Bool)?

    private var startTimers: [UUID: Timer] = [:]
    private var exitSources: [UUID: DispatchSourceProcess] = [:]

    init(root: URL = SessionRegistry.defaultRoot) {
        self.root = root
    }

    // MARK: - beginning

    func begin(id: UUID = UUID(), filePath: String, providerID: String, machineName: String?,
               workingDirectory: String, baseline: Data) throws -> ClaudeSession {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try baseline.write(to: folder.appendingPathComponent("baseline"), options: .atomic)
        let record = ClaudeSession.Record(id: id, filePath: filePath, providerID: providerID,
                                          machineName: machineName, workingDirectory: workingDirectory,
                                          startedAt: Date())
        let s = ClaudeSession(folder: folder, record: record, state: .opening)
        sessions.append(s)
        save(s)
        return s
    }

    func save(_ s: ClaudeSession) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(s.record) else { return }
        try? data.write(to: s.file("session.json"), options: .atomic)
    }

    // MARK: - finding

    /// The session to show for a file: a live one first, else the most recent
    /// one still waiting for Done.
    func session(for path: String, providerID: String) -> ClaudeSession? {
        let mine = sessions.filter { $0.record.filePath == path && $0.record.providerID == providerID }
        return mine.last(where: { $0.isLive }) ?? mine.last
    }

    func liveSession(for path: String, providerID: String) -> ClaudeSession? {
        sessions.last { $0.isLive && $0.record.filePath == path && $0.record.providerID == providerID }
    }

    // MARK: - watching

    /// Wait for the runner to report in, then for it to exit.
    func watch(_ s: ClaudeSession, startTimeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(startTimeout)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if let pid = Self.readPID(s.file("runner.pid")) {
                t.invalidate()
                self.startTimers[s.id] = nil
                self.runnerStarted(s, pid: pid)
            } else if !s.isLive || Date() > deadline {
                t.invalidate()
                self.startTimers[s.id] = nil
                guard s.isLive else { return }
                FileManager.default.createFile(atPath: s.file("abandoned").path, contents: nil)
                self.finish(s, .didNotStart)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        startTimers[s.id] = timer
    }

    private func runnerStarted(_ s: ClaudeSession, pid: Int32) {
        s.record.runnerPID = pid
        if s.state == .opening { s.state = .running }
        save(s)
        onChange?(s)
        attachExitSource(s, pid: pid)
    }

    private func attachExitSource(_ s: ClaudeSession, pid: Int32) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self, weak source] in
            source?.cancel()
            self?.exitSources[s.id] = nil
            self?.runnerExited(s)
        }
        exitSources[s.id] = source
        source.resume()
        // A runner that finished before the source existed never fires it.
        if kill(pid, 0) != 0 && errno == ESRCH {
            source.cancel()
            exitSources[s.id] = nil
            runnerExited(s)
        }
    }

    private func runnerExited(_ s: ClaudeSession) {
        guard s.isLive else { return }
        let report = (try? String(contentsOf: s.file("exit"), encoding: .utf8)).flatMap(SessionRunner.parseExit)
        let changed = fileChanged?(s) ?? false
        finish(s, SessionRunner.outcome(exit: report, endRequested: s.record.endRequested,
                                        isRemote: s.isRemote, fileChanged: changed))
    }

    private func finish(_ s: ClaudeSession, _ outcome: SessionRunner.Outcome) {
        s.state = .ended(outcome)
        s.record.outcome = outcome
        s.record.endedAt = Date()
        save(s)
        onChange?(s)
    }

    // MARK: - ending

    /// End Session: SIGTERM to Claude Code — or to ssh, whose exit hangs up
    /// Claude Code on the far side — then SIGKILL if it is still there three
    /// seconds later. Claude Code sitting at its trust question ignores
    /// SIGTERM (check S5), so the second step is not hypothetical.
    func requestEnd(_ s: ClaudeSession) {
        guard s.state == .running else { return }
        s.record.endRequested = true
        FileManager.default.createFile(atPath: s.file("end-requested").path, contents: nil)
        s.state = .stopping
        save(s)
        onChange?(s)
        guard let target = Self.readPID(s.file("child.pid")) ?? s.record.runnerPID else { return }
        kill(target, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard s.state == .stopping else { return }
            kill(target, SIGKILL)
        }
    }

    /// Done: forget the session, folder and all.
    func discard(_ s: ClaudeSession) {
        startTimers.removeValue(forKey: s.id)?.invalidate()
        exitSources.removeValue(forKey: s.id)?.cancel()
        sessions.removeAll { $0 === s }
        try? FileManager.default.removeItem(at: s.folder)
    }

    // MARK: - after a restart

    /// Pick up the sessions from before Crook last quit.
    ///
    /// A runner still going is recognised by its arguments, which name this
    /// session's launch.command; a reused process ID cannot pass that. One that
    /// finished meanwhile is ended now, as though Crook had watched it. Anything
    /// a week old, or that never started, is cleared away.
    func reattach(now: Date = Date()) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let name = folder.lastPathComponent
            guard !sessions.contains(where: { $0.folder.lastPathComponent == name }) else { continue }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let record = try? JSONDecoder().decode(ClaudeSession.Record.self, from: data) else {
                try? fm.removeItem(at: folder)
                continue
            }
            let s = ClaudeSession(folder: folder, record: record, state: .opening)
            s.handledStart = true
            if let outcome = record.outcome {
                if let ended = record.endedAt, now.timeIntervalSince(ended) > 7 * 86_400 {
                    try? fm.removeItem(at: folder)
                    continue
                }
                s.state = record.restored ? .restored(outcome) : .ended(outcome)
                s.endedWhileAway = true
                sessions.append(s)
                continue
            }
            guard let pid = record.runnerPID ?? Self.readPID(folder.appendingPathComponent("runner.pid")) else {
                // Never started: nothing happened that anyone needs telling about.
                try? fm.removeItem(at: folder)
                continue
            }
            s.record.runnerPID = pid
            s.state = .running
            sessions.append(s)
            if Self.isRunner(pid: pid, of: folder) {
                attachExitSource(s, pid: pid)
            } else {
                s.endedWhileAway = true
                runnerExited(s)
            }
        }
    }

    // MARK: - processes

    static func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether `pid` is alive and running this folder's launch.command.
    static func isRunner(pid: Int32, of folder: URL) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        let script = folder.appendingPathComponent("launch.command").path
        let resolved = folder.resolvingSymlinksInPath().appendingPathComponent("launch.command").path
        return arguments(of: pid)?.contains { $0 == script || $0 == resolved } ?? false
    }

    /// A process's arguments, from the kernel (KERN_PROCARGS2: argc, the
    /// executable path, padding, then the NUL-terminated arguments).
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test.sh claude-registry claude-runner`
Expected: CG-01 to CG-19 `ok`. `claude-runner` still passes, because the runner's `abandoned` check doesn't affect it. "0 failed".

- [ ] **Step 5: Commit**

```bash
git add Crook/Claude/SessionRegistry.swift CrookTests/ClaudeRegistryTests.swift CrookTests/main.swift
git commit -m "Track sessions by their runner, across a Crook restart"
```

---

### Task 5: SessionReview and SessionCopy — what changed, and every sentence

**Files:**
- Create: `Crook/Claude/SessionReview.swift`
- Create: `Crook/Claude/SessionCopy.swift`
- Create: `CrookTests/ClaudeReviewTests.swift`
- Modify: `CrookTests/main.swift`

**Interfaces:**
- Consumes: `UnifiedDiff.between` (existing), `ClaudeSession.State` (Task 4), `SessionRunner.Outcome` (Task 2), `ClaudePreflight.minimumVersion` (Task 3) and `FileProvider` (existing).
- Produces:
  - `SessionReview.changedLines(before:after:) -> [Int]`, `tally(baseline:current:) -> (added: Int, removed: Int)`, `replace(path:on:expecting:with:) throws -> Bool` and `protectedFolder(for:home:) -> String?`.
  - `struct BannerContent: Equatable`, with `Tone` (`live`, `attention`, `warning`, `ended`), `Action` (`showTerminal`, `endSession`, `review`, `undo`, `redo`, `done`), `Button(action:title:help:enabled:)`, and fields `tone`, `title`, `note`, `buttons` and `alsoChanged`.
  - `SessionCopy.Availability` (`available`, `unavailable(String)`), `SessionCopy.BannerFacts`, `SessionCopy.banner(_:) -> BannerContent?` and `swapAvailability(verb:fileVanished:connected:machine:diskMatches:) -> Availability?`.
  - `SessionCopy.Alert(title:message:buttons:)`, with constructors `missing(machine:)`, `tooOld(machine:installed:)`, `notConnected(machine:)`, `conflict(fileName:)`, `vanished(fileName:)`, `folderAccess(protectedFolder:)`, `didNotStart`, `closedWithoutChanges`, `folderMissing(machine:)`, `couldNotConnect(machine:)`, `couldNotOpen(_:)` and `alert(for:machine:protectedFolder:)`.
  - Button and popover strings, `selectionNote(_:)`, `footer(machine:)`, the announcement helpers, `installURL` and `privacyURL`.

- [ ] **Step 1: Write the failing test**

<!-- write: CrookTests/ClaudeReviewTests.swift -->
```swift
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
        let t = SessionReview.tally(baseline: before, current: after)
        T.ok("CV-06  the tally counts lines added and removed", t.added == 2 && t.removed == 2, "\(t)")

        T.suite("claude-review — the banner says")
        func facts(_ state: ClaudeSession.State, added: Int = 0, removed: Int = 0, vanished: Bool = false,
                   nudging: Bool = false, undo: SessionCopy.Availability? = .available,
                   redo: SessionCopy.Availability? = .available, also: [String] = []) -> SessionCopy.BannerFacts {
            .init(state: state, added: added, removed: removed, fileVanished: vanished, machineName: "mac-mini",
                  nudging: nudging, undo: undo, redo: redo, alsoChanged: also)
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
             SessionCopy.swapAvailability(verb: "undo", fileVanished: false, connected: true, machine: nil, diskMatches: false),
             .unavailable("This file has changed since the session ended."))
        T.ok("CV-18  and never for a file that moved",
             SessionCopy.swapAvailability(verb: "undo", fileVanished: true, connected: true, machine: nil, diskMatches: true) == nil)

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
    }
}
```

In `CrookTests/main.swift` add:

```swift
if want("claude-review") { ClaudeReviewTests.run() }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh claude-review`
Expected: compile errors for `SessionReview`, `SessionCopy` and `BannerContent`.

- [ ] **Step 3: Write SessionReview**

<!-- write: Crook/Claude/SessionReview.swift -->
```swift
import Foundation

/// The arithmetic of reviewing a session: which lines to highlight, how much
/// changed, and putting bytes back.
enum SessionReview {

    /// Lines in `after` that are new since `before`, 1-based: every added line,
    /// and for a pure removal the line now sitting where it was.
    ///
    /// Precise rather than LineDiff's first-to-last span, which is the right
    /// call for a single agent rewrite and the wrong one for a rename: two
    /// touched lines seventy apart would light up seventy-eight.
    static func changedLines(before: String, after: String) -> [Int] {
        guard before != after else { return [] }
        let (lines, _) = UnifiedDiff.between(before, after, context: 1)
        let total = after.components(separatedBy: "\n").count
        var out = Set<Int>()
        var removalPending = false
        for line in lines {
            switch line.kind {
            case .added:
                if let n = line.newNo { out.insert(n) }
                removalPending = false
            case .removed:
                removalPending = true
            case .context:
                if removalPending, let n = line.newNo { out.insert(n) }
                removalPending = false
            case .gap:
                break
            }
        }
        if removalPending { out.insert(max(1, total)) }
        return out.sorted()
    }

    static func tally(baseline: String, current: String) -> (added: Int, removed: Int) {
        guard baseline != current else { return (0, 0) }
        let summary = UnifiedDiff.between(baseline, current).1
        return (summary.added, summary.removed)
    }

    /// Replace a file's bytes only if they are still exactly `expecting`.
    ///
    /// Undo and Redo each promise to replace one specific version. Anything
    /// else on disk — the person's own edit, another agent's — is left alone,
    /// and false says nothing was written.
    static func replace(path: String, on provider: FileProvider, expecting: Data, with bytes: Data) throws -> Bool {
        guard provider.contents(path) == expecting else { return false }
        try provider.write(bytes, to: path)
        return true
    }

    /// The folder macOS guards behind a privacy grant, by the name System
    /// Settings uses for it.
    static func protectedFolder(for path: String, home: String) -> String? {
        for name in ["Desktop", "Documents", "Downloads"] {
            let root = home + "/" + name
            if path == root || path.hasPrefix(root + "/") { return name }
        }
        return nil
    }
}
```

- [ ] **Step 4: Write SessionCopy**

<!-- write: Crook/Claude/SessionCopy.swift -->
```swift
import Foundation

/// What the banner across the editor shows. A value, so what a state looks
/// like can be tested without drawing it.
struct BannerContent: Equatable {
    enum Tone: Equatable { case live, attention, warning, ended }
    enum Action: Equatable { case showTerminal, endSession, review, undo, redo, done }

    struct Button: Equatable {
        let action: Action
        let title: String
        var help: String? = nil
        var enabled = true
    }

    var tone: Tone
    var title: String
    var note: String?
    var buttons: [Button]
    /// Other files that changed during the session, relative to its folder.
    var alsoChanged: [String]
}

/// Every sentence Edit with Claude shows, in one place — so the copy can be
/// read as the design it is, and tested like one.
enum SessionCopy {

    // MARK: - title bar

    static let button = "Edit with Claude"
    static let buttonOpening = "Opening…"
    static let buttonRunning = "Editing with Claude"
    static let buttonHelp = "Describe a change and Claude Code makes it (⇧⌘E)"
    static let buttonRunningHelp = "Show the Claude Code session in Terminal (⇧⌘E)"
    static let vanishedHelp = "This file is no longer on disk."

    // MARK: - popover

    static let placeholder = "Describe the change, or leave this empty to talk it through"
    static let openButton = "Open Claude Code"
    static let tip = "Tip: select part of the file first to point Claude at it."
    /// Named, because the trust question's default answer is No (check S4).
    static let firstTime = "The first time, Claude Code may ask you to log in. In a folder it hasn't seen before, it asks whether you trust it: choose “Yes, I trust this folder”."

    static func selectionNote(_ r: ClosedRange<Int>) -> String {
        r.lowerBound == r.upperBound ? "Line \(r.lowerBound) selected" : "Lines \(r.lowerBound)–\(r.upperBound) selected"
    }

    static func footer(machine: String?) -> String {
        if let machine {
            return "Opens Claude Code on \(machine), in Terminal beside this window. Each change appears here as Claude saves it."
        }
        return "Opens Claude Code in Terminal, beside this window. Each change appears here as Claude saves it."
    }

    // MARK: - banner

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    struct BannerFacts: Equatable {
        var state: ClaudeSession.State
        var added: Int
        var removed: Int
        var fileVanished: Bool
        var machineName: String?
        var nudging: Bool
        /// nil: not offered at all.
        var undo: Availability?
        var redo: Availability?
        var alsoChanged: [String]
    }

    /// U+2212 MINUS SIGN, as the rail uses, so the figures line up.
    static func tally(_ added: Int, _ removed: Int) -> String { "+\(added) \u{2212}\(removed)" }

    static func banner(_ f: BannerFacts) -> BannerContent? {
        let showTerminal = BannerContent.Button(action: .showTerminal, title: "Show Terminal")
        let endSession = BannerContent.Button(action: .endSession, title: "End Session")
        let review = BannerContent.Button(action: .review, title: "Review Changes")
        let done = BannerContent.Button(action: .done, title: "Done")
        let changed = f.added + f.removed > 0

        switch f.state {
        case .opening:
            return BannerContent(tone: .live, title: "Opening Claude Code in Terminal…", note: nil,
                                 buttons: [], alsoChanged: [])
        case .stopping:
            return BannerContent(tone: .live, title: "Ending the session…", note: nil, buttons: [], alsoChanged: [])
        case .running:
            if f.fileVanished {
                return BannerContent(tone: .warning, title: "Claude moved or deleted this file",
                                     note: "The sidebar shows what's there now",
                                     buttons: [showTerminal, endSession], alsoChanged: [])
            }
            let note: String
            if f.nudging { note = "To edit it yourself, finish in Terminal or click End Session" }
            else if changed { note = "\(tally(f.added, f.removed)) so far · read-only until you finish" }
            else { note = "Read-only here until you finish" }
            return BannerContent(tone: f.nudging ? .attention : .live, title: "Editing with Claude in Terminal",
                                 note: note, buttons: [showTerminal, endSession], alsoChanged: [])
        case .ended(let outcome):
            let title: String, tone: BannerContent.Tone, since: String
            switch outcome {
            case .finished:
                title = "Finished editing with Claude"; tone = .ended; since = "in this file"
            case .connectionLost:
                title = "The connection to \(f.machineName ?? "that Mac") closed, which ended the session"
                tone = .warning; since = "saved before it closed"
            case .stoppedUnexpectedly:
                title = "Claude Code stopped unexpectedly"; tone = .warning; since = "saved before it stopped"
            default:
                return nil   // an alert says these; there is nothing to review
            }
            var buttons: [BannerContent.Button] = []
            let note: String
            if f.fileVanished {
                note = "This file was moved or deleted"
                if changed { buttons.append(review) }
            } else if changed {
                note = "\(tally(f.added, f.removed)) \(since)"
                buttons.append(review)
                if let undo = f.undo { buttons.append(button(.undo, "Undo Changes", undo)) }
            } else {
                note = "This file wasn't changed"
            }
            buttons.append(done)
            return BannerContent(tone: tone, title: title, note: note, buttons: buttons, alsoChanged: f.alsoChanged)
        case .restored:
            var buttons: [BannerContent.Button] = []
            if let redo = f.redo { buttons.append(button(.redo, "Redo Changes", redo)) }
            buttons.append(done)
            return BannerContent(tone: .ended, title: "Restored the version from before Claude's changes",
                                 note: nil, buttons: buttons, alsoChanged: [])
        }
    }

    private static func button(_ action: BannerContent.Action, _ title: String,
                               _ availability: Availability) -> BannerContent.Button {
        switch availability {
        case .available: return .init(action: action, title: title)
        case .unavailable(let why): return .init(action: action, title: title, help: why, enabled: false)
        }
    }

    /// Whether Undo or Redo can run right now, why not, or nil when it should
    /// not be offered at all.
    static func swapAvailability(verb: String, fileVanished: Bool, connected: Bool,
                                 machine: String?, diskMatches: Bool) -> Availability? {
        if fileVanished { return nil }
        if !connected { return .unavailable("Reconnect to \(machine ?? "that Mac") to \(verb).") }
        return diskMatches ? .available : .unavailable("This file has changed since the session ended.")
    }

    // MARK: - VoiceOver

    static let startedAnnouncement = "Claude Code is open in Terminal."

    static func changedAnnouncement(_ lines: [Int]) -> String {
        guard let first = lines.first, let last = lines.last else { return "" }
        return first == last ? "Claude changed line \(first)." : "Claude changed lines \(first) to \(last)."
    }

    static func endedAnnouncement(added: Int, removed: Int) -> String {
        added + removed == 0
            ? "Claude's session has ended. This file wasn't changed."
            : "Claude's session has ended. \(added) lines added, \(removed) removed."
    }

    // MARK: - alerts

    struct Alert: Equatable {
        let title: String
        let message: String
        let buttons: [String]
    }

    static func missing(machine: String?) -> Alert {
        guard let machine else {
            return Alert(title: "Claude Code isn't installed on this Mac.",
                         message: "Edit with Claude opens Claude Code, which isn't installed here yet. Install it, then try again.",
                         buttons: ["How to Install", "OK"])
        }
        return Alert(title: "Claude Code isn't installed on \(machine).",
                     message: "Claude works on the Mac where the file lives. Install Claude Code on \(machine), then try again.",
                     buttons: ["How to Install", "OK"])
    }

    static func tooOld(machine: String?, installed: String) -> Alert {
        Alert(title: "Claude Code on \(machine ?? "this Mac") needs an update.",
              message: "Edit with Claude needs version \(ClaudePreflight.minimumVersion) or later. \(machine ?? "This Mac") has \(installed).",
              buttons: ["Update in Terminal", "Cancel"])
    }

    static func notConnected(machine: String) -> Alert {
        Alert(title: "Crook isn't connected to \(machine).",
              message: "Reconnect to open Claude Code there. Your file hasn't changed.",
              buttons: ["Reconnect", "Cancel"])
    }

    static func conflict(fileName: String) -> Alert {
        Alert(title: "\(fileName) changed on disk while you were editing.",
              message: "Choose the version Claude should work on.",
              buttons: ["Use My Version", "Use Disk Version", "Cancel"])
    }

    static func vanished(fileName: String) -> Alert {
        Alert(title: "\(fileName) is no longer on disk.", message: "It may have been moved or deleted.", buttons: ["OK"])
    }

    static func folderAccess(protectedFolder: String?) -> Alert {
        let message = protectedFolder.map {
            "macOS hasn't given Terminal access to your \($0) folder. Turn it on in System Settings, then try again."
        } ?? "macOS didn't let Terminal open that folder. Check Terminal under Files and Folders in System Settings, then try again."
        return Alert(title: "Terminal can't open the folder this file is in.", message: message,
                     buttons: ["Open Privacy Settings", "OK"])
    }

    static let didNotStart = Alert(title: "Claude Code didn't start.",
                                   message: "If a Terminal window opened, it shows what went wrong.",
                                   buttons: ["OK"])

    static let closedWithoutChanges = Alert(
        title: "Claude Code closed without making changes.",
        message: "If it asked whether to trust this folder, try again and choose “Yes, I trust this folder”. Otherwise, Terminal shows what went wrong.",
        buttons: ["Try Again", "OK"])

    static func folderMissing(machine: String?) -> Alert {
        Alert(title: machine.map { "The folder for this file is missing on \($0)." } ?? "The folder for this file is missing.",
              message: "Claude Code needs to start in that folder. It may have been moved or renamed.",
              buttons: ["OK"])
    }

    static func couldNotConnect(machine: String?) -> Alert {
        Alert(title: "Couldn't reach \(machine ?? "that Mac") from Terminal.",
              message: "ssh reported a problem, and Terminal shows what it said. Check that Crook is still connected, then try again.",
              buttons: ["OK"])
    }

    static func couldNotOpen(_ reason: String) -> Alert {
        Alert(title: "Couldn't open Claude Code.", message: reason, buttons: ["OK"])
    }

    /// The alert that stands in for a banner, for endings with nothing to review.
    static func alert(for outcome: SessionRunner.Outcome, machine: String?, protectedFolder: String?) -> Alert? {
        switch outcome {
        case .claudeMissing: return missing(machine: machine)
        case .folderMissing: return folderMissing(machine: machine)
        case .folderAccess: return folderAccess(protectedFolder: protectedFolder)
        case .couldNotConnect: return couldNotConnect(machine: machine)
        case .closedWithoutChanges: return closedWithoutChanges
        case .didNotStart: return didNotStart
        case .finished, .connectionLost, .stoppedUnexpectedly: return nil
        }
    }

    static let installURL = URL(string: "https://code.claude.com/docs/en/setup")!
    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test.sh claude-review diff`
Expected: CV-01 to CV-27 `ok`, and `diff` still passes. "0 failed".

- [ ] **Step 6: Commit**

```bash
git add Crook/Claude/SessionReview.swift Crook/Claude/SessionCopy.swift CrookTests/ClaudeReviewTests.swift CrookTests/main.swift
git commit -m "Say what a session did, in Crook's words, and put bytes back exactly"
```

---

### Task 6: The editor during a session — read-only, reveal, banner

**Files:**
- Modify: `web/src/editor.js`
- Modify: `Crook/Editor/EditorBridge.swift`
- Modify: `Crook/Editor/DiffOverlay.swift`
- Modify: `Crook/Editor/EditorViewController.swift`
- Create: `Crook/Claude/SessionBanner.swift`

**Interfaces:**
- Consumes: `BannerContent` (Task 5).
- Produces:
  - JS: `CrookEditor.setReadOnly(on)`, `CrookEditor.revealLine(n)`, and message `{type: "readOnlyAttempt"}`.
  - `EditorBridge.setReadOnly(_ on: Bool)`, `revealLine(_ n: Int)`, `selection(_ done: @escaping (Int, Int) -> Void)` and `var onReadOnlyAttempt: (() -> Void)?`.
  - `EditorViewController.setBanner(_ content: BannerContent?, onAction:onOpenFile:)`, `pulseBanner()` and `showDiff(old:new:title:since:)`.
  - `DiffOverlay.present(old:new:title:since:onDismiss:)`.
  - `SessionBanner` (NSView), with `apply(_:)`, `pulse()`, `onAction`, `onOpenFile`, and `static changedYellow: NSColor`.

This task is AppKit and WebKit wiring, which the harness can't drive. Its verification is that the app builds, that every existing suite still passes, and a manual check of read-only and reveal in Task 9.

- [ ] **Step 1: editor.js — read-only while Claude has the file**

In `web/src/editor.js`, change the state import line to add `Compartment`:

```js
import { EditorState, StateField, StateEffect, Annotation, RangeSetBuilder, Prec, Compartment } from "@codemirror/state"
```

Directly above the line `// ---------------------------------------------------------------- theme`, insert:

```js
// ---------------------------------------------------------------- read-only while Claude edits

// One writer at a time. While an Edit with Claude session has this file, Crook
// shows it live and refuses input; selecting, copying and scrolling still
// work. An attempt to type is reported, so the banner can say why nothing
// happened rather than the editor silently ignoring keys.
const readOnlyConf = new Compartment()
let readOnly = false
let lastWheel = 0

function reportAttempt() { post({ type: "readOnlyAttempt" }) }

const readOnlyGuard = EditorView.domEventHandlers({
  keydown(e) {
    if (!readOnly) return false
    if (e.metaKey || e.ctrlKey) {
      const k = (e.key || "").toLowerCase()
      if (k === "v" || k === "x" || k === "z" || k === "y") reportAttempt()
      return false
    }
    if ((e.key && e.key.length === 1) || e.key === "Backspace" || e.key === "Delete" || e.key === "Enter" || e.key === "Tab") {
      reportAttempt()
    }
    return false
  },
  beforeinput(e) {
    if (!readOnly) return false
    reportAttempt()
    // Dictation and the emoji picker arrive here, not as keys.
    if (e.cancelable) e.preventDefault()
    return true
  },
  paste(e) {
    if (!readOnly) return false
    reportAttempt()
    e.preventDefault()
    return true
  },
  drop(e) {
    if (!readOnly) return false
    reportAttempt()
    e.preventDefault()
    return true
  },
  wheel() {
    lastWheel = Date.now()
    return false
  },
})

function setReadOnly(on) {
  readOnly = !!on
  if (!view) return
  view.dispatch({
    effects: readOnlyConf.reconfigure(EditorState.readOnly.of(readOnly)),
    annotations: [fromSwift.of(true)],
  })
}

/// Bring a line Claude just changed into view — unless the reader is
/// scrolling, or can already see it. Following along should never mean being
/// dragged away from what you were reading.
function revealLine(n) {
  if (!view) return
  if (Date.now() - lastWheel < 3000) return
  const doc = view.state.doc
  const line = doc.line(Math.max(1, Math.min(n | 0, doc.lines)))
  const box = view.scrollDOM.getBoundingClientRect()
  const at = view.coordsAtPos(line.from)
  if (at && at.top >= box.top && at.bottom <= box.bottom) return
  view.dispatch({
    effects: EditorView.scrollIntoView(line.from, { y: "start", yMargin: Math.round(view.scrollDOM.clientHeight / 3) }),
    annotations: [fromSwift.of(true)],
  })
}

```

In `mount`, add two entries to `extensions`, directly after `changedLines,`:

```js
        readOnlyConf.of(EditorState.readOnly.of(readOnly)),
        readOnlyGuard,
```

Change the export line to:

```js
export { mount, setDocument, applyRemote, getText, getLength, getSelection, focus, selectRange, applyDiagnostics, applyChangedLines, flushNow, setScale, zoomIn, zoomOut, zoomReset, setReadOnly, revealLine }
```

- [ ] **Step 2: EditorBridge — carry read-only, reveal and selection**

In `Crook/Editor/EditorBridge.swift`, after `var onReady: (() -> Void)?`, add:

```swift
    /// The reader tried to type while an Edit with Claude session has the file.
    var onReadOnlyAttempt: (() -> Void)?
    private var readOnly = false
```

In `userContentController(_:didReceive:)`, in `case "editorReady":`, directly after `pushDocument()` add:

```swift
            // A web content process that crashed and reloaded mid-session
            // must come back read-only, not quietly editable.
            pushReadOnly()
```

In the same switch, add a case before `case "jserror":`:

```swift
        case "readOnlyAttempt":
            onReadOnlyAttempt?()
```

After `func pushChangedLines(_ lines: [Int]) { … }`, add:

```swift
    /// Refuse input while an Edit with Claude session has the file.
    func setReadOnly(_ on: Bool) {
        guard on != readOnly else { return }
        readOnly = on
        pushReadOnly()
    }

    private func pushReadOnly() {
        guard isReady, let wv = webView else { return }
        wv.callAsyncJavaScript("CrookEditor.setReadOnly(r);", arguments: ["r": readOnly],
                               in: nil, in: .page) { _ in }
    }

    func revealLine(_ line: Int) {
        guard isReady, let wv = webView else { return }
        wv.callAsyncJavaScript("CrookEditor.revealLine(n);", arguments: ["n": line],
                               in: nil, in: .page) { _ in }
    }

    /// The current selection as UTF-16 offsets into the canonical buffer.
    func selection(_ done: @escaping (_ anchor: Int, _ head: Int) -> Void) {
        guard isReady, let wv = webView else { done(caret, caret); return }
        wv.evaluateJavaScript("CrookEditor.getSelection()") { [weak self] value, _ in
            let fallback = self?.caret ?? 0
            let d = value as? [String: Any]
            let anchor = d?["anchor"] as? Int ?? fallback
            done(anchor, d?["head"] as? Int ?? anchor)
        }
    }
```

- [ ] **Step 3: DiffOverlay — say what the diff is measured from**

In `Crook/Editor/DiffOverlay.swift`, replace:

```swift
    func present(old: String, new: String, title: String, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        let (lines, summary) = UnifiedDiff.between(old, new)

        let body = summary.isEmpty
            ? "no textual change"
            : "\(summary.added) added, \(summary.removed) removed since you last opened it"
```

with:

```swift
    /// `since` finishes the header's sentence. nil when the title already
    /// says what the diff is measured from.
    func present(old: String, new: String, title: String, since: String? = "since you last opened it",
                 onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        let (lines, summary) = UnifiedDiff.between(old, new)

        let counts = "\(summary.added) added, \(summary.removed) removed"
        let body = summary.isEmpty ? "no textual change" : (since.map { "\(counts) \($0)" } ?? counts)
```

- [ ] **Step 4: EditorViewController — host the banner**

In `Crook/Editor/EditorViewController.swift`, after `private var empty: EmptyStateView!`, add:

```swift
    /// The Edit with Claude banner, and the two ways the text can meet the top
    /// of the pane: under the banner, or at the top when there is none.
    private let banner = SessionBanner()
    private var webTopToView: NSLayoutConstraint!
    private var webTopToBanner: NSLayoutConstraint!
```

In `loadView()`, replace:

```swift
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
```

with:

```swift
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // The banner pushes the text down rather than covering it: the top
        // lines are as likely as any to be the ones Claude just changed.
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        container.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        webTopToView = webView.topAnchor.constraint(equalTo: container.topAnchor)
        webTopToBanner = webView.topAnchor.constraint(equalTo: banner.bottomAnchor)
        webTopToView.isActive = true
        // attachToContentLayoutGuide only adds a top constraint when there is
        // none; there now always is.
        topConstraint = webTopToView
```

Replace `showDiff`:

```swift
    func showDiff(old: String, new: String, title: String) {
```

with:

```swift
    func showDiff(old: String, new: String, title: String, since: String? = "since you last opened it") {
```

and inside it replace `d.present(old: old, new: new, title: title) { [weak self] in self?.dismissDiff() }` with:

```swift
        d.present(old: old, new: new, title: title, since: since) { [weak self] in self?.dismissDiff() }
```

After `func setReach(_ text: String) { … }`, add:

```swift
    /// Show, update or remove the Edit with Claude banner.
    func setBanner(_ content: BannerContent?,
                   onAction: @escaping (BannerContent.Action) -> Void = { _ in },
                   onOpenFile: @escaping (String) -> Void = { _ in }) {
        guard let content else {
            guard !banner.isHidden else { return }
            banner.isHidden = true
            webTopToBanner.isActive = false
            webTopToView.isActive = true
            return
        }
        banner.onAction = onAction
        banner.onOpenFile = onOpenFile
        banner.apply(content)
        guard banner.isHidden else { return }
        banner.isHidden = false
        webTopToView.isActive = false
        webTopToBanner.isActive = true
    }

    func pulseBanner() { banner.pulse() }
```

- [ ] **Step 5: SessionBanner**

<!-- write: Crook/Claude/SessionBanner.swift -->
```swift
import AppKit

/// The strip across the top of the editor while a file is in an Edit with
/// Claude session, and after one ends.
///
/// AppKit, like every control in Crook; the web view stays at zero controls.
/// Its colours are Crook's own paper with a trace of highlighter, and its dot is
/// the yellow the editor marks changed lines with — yellow means Claude.
final class SessionBanner: NSView {

    var onAction: ((BannerContent.Action) -> Void)?
    var onOpenFile: ((String) -> Void)?
    private(set) var content: BannerContent?

    private let dot = BannerDot()
    private let titleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private let alsoRow = NSStackView()
    private let separator = NSBox()

    private static let actions: [BannerContent.Action] = [.showTerminal, .endSession, .review, .undo, .redo, .done]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 10, for: .horizontal)
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        alsoRow.orientation = .horizontal
        alsoRow.spacing = 3
        separator.boxType = .separator

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [dot, titleLabel, noteLabel, spacer, buttonRow])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8

        let rows = NSStackView(views: [top, alsoRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 3
        rows.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)

        for v in [rows, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: separator.topAnchor),
            top.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ c: BannerContent) {
        guard c != content else { return }
        content = c
        titleLabel.stringValue = c.title
        noteLabel.stringValue = c.note ?? ""
        noteLabel.isHidden = c.note == nil
        dot.color = Self.dotColor(c.tone)
        setAccessibilityLabel([c.title, c.note].compactMap { $0 }.joined(separator: ". "))

        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for b in c.buttons {
            let button = NSButton(title: b.title, target: self, action: #selector(tapped(_:)))
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.isEnabled = b.enabled
            button.toolTip = b.help
            button.tag = Self.actions.firstIndex(of: b.action) ?? 0
            buttonRow.addArrangedSubview(button)
        }

        alsoRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        alsoRow.isHidden = c.alsoChanged.isEmpty
        if !c.alsoChanged.isEmpty {
            alsoRow.addArrangedSubview(Self.small("Also changed during the session:"))
            let shown = Array(c.alsoChanged.prefix(3))
            for (i, path) in shown.enumerated() {
                let link = NSButton(title: path, target: self, action: #selector(openFile(_:)))
                link.isBordered = false
                link.font = .systemFont(ofSize: 11.5)
                link.contentTintColor = .labelColor
                link.setAccessibilityLabel("Open \(path)")
                alsoRow.addArrangedSubview(link)
                if i < shown.count - 1 { alsoRow.addArrangedSubview(Self.small(",")) }
            }
            if c.alsoChanged.count > 3 { alsoRow.addArrangedSubview(Self.small("and \(c.alsoChanged.count - 3) more")) }
        }
        needsDisplay = true
    }

    /// Someone tried to type: draw the eye here, once, unless motion is reduced.
    func pulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Self.changedYellow.cgColor
        }
        layer.borderWidth = 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.layer?.borderWidth = 0 }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let tone = content?.tone ?? .live
        layer?.backgroundColor = (tone == .live || tone == .attention ? Self.liveTint : Self.endedTint).cgColor
    }

    @objc private func tapped(_ sender: NSButton) {
        guard Self.actions.indices.contains(sender.tag) else { return }
        onAction?(Self.actions[sender.tag])
    }

    @objc private func openFile(_ sender: NSButton) { onOpenFile?(sender.title) }

    private static func small(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = .secondaryLabelColor
        return l
    }

    // MARK: - colour

    private static func color(light: UInt32, dark: UInt32) -> NSColor {
        func make(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? make(dark) : make(light)
        }
    }

    /// Paper with a trace of highlighter, while Claude has the file.
    static let liveTint = color(light: 0xFAF3DA, dark: 0x2A2619)
    /// Plain warm paper once it's over.
    static let endedTint = color(light: 0xF4F1E9, dark: 0x24221E)
    /// theme.css --c-changed: the colour of a line Claude changed.
    static let changedYellow = color(light: 0xC79A2E, dark: 0xD8B25C)

    private static func dotColor(_ tone: BannerContent.Tone) -> NSColor {
        switch tone {
        case .live, .attention: return changedYellow
        case .warning: return .systemRed
        case .ended: return .tertiaryLabelColor
        }
    }
}

/// A small round mark in a colour that follows the appearance.
private final class BannerDot: NSView {
    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = bounds.height / 2
    }
}
```

- [ ] **Step 6: Build and run every suite**

Run: `./scripts/build.sh && ./scripts/test.sh`
Expected: "==> built build/Crook.app", then all suites pass with "0 failed". If esbuild reports an error in `editor.js`, fix it before continuing.

- [ ] **Step 7: Commit**

```bash
git add web/src/editor.js Crook/Editor/EditorBridge.swift Crook/Editor/DiffOverlay.swift Crook/Editor/EditorViewController.swift Crook/Claude/SessionBanner.swift
git commit -m "Let the editor sit still while Claude has the file, and say so"
```

---

### Task 7: The title bar button and the popover

**Files:**
- Create: `Crook/Claude/ClaudeButton.swift`
- Create: `Crook/Claude/AskPopover.swift`

**Interfaces:**
- Consumes: `SessionCopy` strings (Task 5) and `SessionBanner.changedYellow` (Task 6).
- Produces:
  - `ClaudeButton: NSTitlebarAccessoryViewController`, with `Mode` (`hidden`, `idle`, `disabled`, `opening`, `running`), `setMode(_:)`, `setCompact(_:)`, `onClick: ((Bool) -> Void)?` (true when ⌥ was held), and `anchor: NSView`.
  - `AskPopover: NSViewController`, with `Context(breadcrumb:selectedLines:machineName:showTip:showFirstTime:draft:)`, `onOpen: ((String) -> Void)?` and `onDraftChange: ((String) -> Void)?`.

Verification is the build here. The views are exercised end to end in Task 9.

- [ ] **Step 1: ClaudeButton**

<!-- write: Crook/Claude/ClaudeButton.swift -->
```swift
import AppKit

/// Edit with Claude, at the trailing end of the title bar.
///
/// A title bar accessory rather than a toolbar item. Crook has no toolbar on
/// purpose — an empty one reserves a band of chrome — and an accessory sits in
/// the title row without bringing that band back.
final class ClaudeButton: NSTitlebarAccessoryViewController {

    enum Mode: Equatable { case hidden, idle, disabled, opening, running }

    /// True when ⌥ was held: skip the popover.
    var onClick: ((_ optionHeld: Bool) -> Void)?
    private(set) var mode: Mode = .hidden
    private var compact = false

    private let button = NSButton()
    private let spinner = NSProgressIndicator()

    /// What the popover hangs from.
    var anchor: NSView { button }

    override func loadView() {
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        button.target = self
        button.action = #selector(clicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let stack = NSStackView(views: [spinner, button])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 176, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 4),
        ])
        view = container
        apply()
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        apply()
    }

    /// Below a narrow window width the label gives way to the symbol, and
    /// moves into the tooltip.
    func setCompact(_ c: Bool) {
        guard c != compact else { return }
        compact = c
        apply()
    }

    @objc private func clicked() {
        onClick?(NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    private func apply() {
        guard isViewLoaded else { return }
        isHidden = mode == .hidden

        let title: String
        let image: NSImage?
        let help: String
        switch mode {
        case .hidden, .idle, .disabled:
            title = SessionCopy.button
            image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            help = mode == .disabled ? SessionCopy.vanishedHelp : SessionCopy.buttonHelp
        case .opening:
            title = SessionCopy.buttonOpening
            image = nil
            help = SessionCopy.buttonOpening
        case .running:
            title = SessionCopy.buttonRunning
            // Yellow means Claude: the same colour as a changed line.
            image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
                    .applying(.init(paletteColors: [SessionBanner.changedYellow])))
            help = SessionCopy.buttonRunningHelp
        }

        let showTitle = !compact || mode == .opening
        button.title = showTitle ? title : ""
        button.image = image
        button.imagePosition = showTitle ? (image == nil ? .noImage : .imageLeading) : .imageOnly
        button.toolTip = showTitle ? help : "\(title) — \(help)"
        button.setAccessibilityLabel(title)
        button.isEnabled = mode == .idle || mode == .running
        if mode == .opening { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
```

- [ ] **Step 2: AskPopover**

<!-- write: Crook/Claude/AskPopover.swift -->
```swift
import AppKit

/// The question Edit with Claude asks before Terminal opens.
///
/// Typing is optional; Return always opens the session. It exists because the
/// first instruction is usually the only one, and it is better given here — in
/// the app the person is already looking at, beside the selection it applies
/// to — than typed into Terminal after waiting for a greeting.
final class AskPopover: NSViewController, NSTextViewDelegate {

    struct Context {
        var breadcrumb: String
        var selectedLines: ClosedRange<Int>?
        var machineName: String?
        var showTip: Bool
        var showFirstTime: Bool
        var draft: String
    }

    var onOpen: ((String) -> Void)?
    var onDraftChange: ((String) -> Void)?

    private let context: Context
    private let textView = NSTextView()
    private let placeholder = NSTextField(wrappingLabelWithString: SessionCopy.placeholder)
    private var fieldHeight: NSLayoutConstraint!

    private static let width: CGFloat = 340
    private static let lineHeight: CGFloat = 17

    init(context: Context) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let inner = Self.width - 28

        let crumb = NSTextField(labelWithString: context.breadcrumb)
        crumb.font = .systemFont(ofSize: 12, weight: .semibold)
        crumb.lineBreakMode = .byTruncatingMiddle
        crumb.widthAnchor.constraint(lessThanOrEqualToConstant: inner).isActive = true
        var rows: [NSView] = [crumb]

        if let lines = context.selectedLines {
            rows.append(Self.label(SessionCopy.selectionNote(lines), size: 11.5, color: .secondaryLabelColor, width: inner))
        } else if context.showTip {
            rows.append(Self.label(SessionCopy.tip, size: 11.5, color: .tertiaryLabelColor, width: inner))
        }

        rows.append(makeField(width: inner))
        rows.append(Self.label(SessionCopy.footer(machine: context.machineName), size: 11,
                               color: .secondaryLabelColor, width: inner))
        if context.showFirstTime {
            rows.append(Self.label(SessionCopy.firstTime, size: 11, color: .tertiaryLabelColor, width: inner))
        }

        let open = NSButton(title: SessionCopy.openButton, target: self, action: #selector(openTapped))
        open.bezelStyle = .push
        open.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [NSView(), open])
        buttonRow.orientation = .horizontal
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        rows.append(buttonRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
            buttonRow.widthAnchor.constraint(equalToConstant: inner),
        ])
        view = root
        updateHeight()
    }

    private func makeField(width: CGFloat) -> NSView {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 3, height: 5)
        // What the person types reaches Claude verbatim; curly quotes and
        // dashes it did not type would reach it too.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.frame = NSRect(x: 0, y: 0, width: width - 2, height: 60)
        textView.string = context.draft
        textView.delegate = self
        textView.setAccessibilityLabel(SessionCopy.placeholder)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        placeholder.preferredMaxLayoutWidth = width - 20
        placeholder.isHidden = !context.draft.isEmpty

        let box = FieldBox()
        for v in [box, scroll, placeholder] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        box.addSubview(scroll)
        box.addSubview(placeholder)
        fieldHeight = box.heightAnchor.constraint(equalToConstant: Self.lineHeight * 3 + 12)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            fieldHeight,
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            placeholder.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            placeholder.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -9),
        ])
        return box
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Return opens the session; Shift-Return starts a new line.
    func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            tv.insertNewlineIgnoringFieldEditor(nil)
        } else {
            openTapped()
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        onDraftChange?(textView.string)
        updateHeight()
    }

    @objc private func openTapped() { onOpen?(textView.string) }

    /// Three lines tall, growing with the request to eight, then scrolling.
    private func updateHeight() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height + textView.textContainerInset.height * 2
        let lines = max(3, min(8, Int((used / Self.lineHeight).rounded(.up))))
        fieldHeight.constant = CGFloat(lines) * Self.lineHeight + 12
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private static func label(_ s: String, size: CGFloat, color: NSColor, width: CGFloat) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.preferredMaxLayoutWidth = width
        return l
    }
}

/// The request field's frame: a hairline and the text background, like any
/// other text field.
private final class FieldBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
```

- [ ] **Step 3: Build**

Run: `./scripts/build.sh`
Expected: "==> built build/Crook.app". Nothing uses these views yet; this confirms they compile against the macOS 26 SDK.

- [ ] **Step 4: Commit**

```bash
git add Crook/Claude/ClaudeButton.swift Crook/Claude/AskPopover.swift
git commit -m "The Edit with Claude button, and the question it asks"
```

---

### Task 8: SessionController, and wiring it into the window

**Files:**
- Create: `Crook/Claude/SessionController.swift`
- Modify: `Crook/WorkspaceWindowController.swift`
- Modify: `Crook/CrookDocument.swift`
- Modify: `Crook/Workspace/Workspace.swift`
- Modify: `Crook/Workspace/RailViewController.swift`
- Modify: `Crook/AppDelegate.swift`

**Interfaces:**
- Consumes everything from Tasks 1 to 7, plus the existing `WorkspaceWindowController` (`editor`, `rail`, `document`, `retarget(to:)`, `reconnect(to:)`, `markEngaged()`, `showChanges(_:)`), `CrookDocument` (`fileURL`, `remoteProviderID`, `currentText()`, `reloadFromDisk()`, `reloadFromDiskDiscardingEdits(_:)`, `saveRemote()`), `Workspace.shared.breadcrumb(for:)`, `importedURLs()`, `Workspace.importedPaths(forProviderID:)`, `Providers`, `RemoteProvider.transport`, and `ByteCodec.decode`.
- Produces:
  - `SessionController`, with `refresh()`, `hasSession(for:)`, `changeLanded(url:before:after:) -> Bool`, `fileVanished(_:)`, `userEdited(_:)`, `reviewBaseline(for:) -> (text: String, title: String)?`, `menuEditWithClaude()`, `menuEditWithClaudeNow()`, `menuEndSession()` and `validate(_:) -> Bool`.
  - `WorkspaceWindowController`: `sessions`, `fileVanished`, `hasConflict`, `@objc editWithClaude(_:)`, `@objc editWithClaudeNow(_:)` and `@objc endClaudeSession(_:)`.
  - `CrookDocument.saveBeforeSession() -> Bool`.
  - `Workspace.filePaths(under:) -> [String]`.

- [ ] **Step 1: SessionController**

<!-- write: Crook/Claude/SessionController.swift -->
```swift
import AppKit

/// Edit with Claude, for the workspace window.
///
/// The title bar button, the popover, the checks before Terminal opens, watch
/// mode, and what happens when a session ends. A session belongs to Terminal
/// and outlives Crook, so this object never owns one: SessionRegistry knows
/// what is running, and everything shown here is recomputed from that, from
/// the open document, and from the disk.
final class SessionController: NSObject, NSPopoverDelegate {

    private unowned let wc: WorkspaceWindowController
    private let registry: SessionRegistry
    let accessory = ClaudeButton()

    private var popover: NSPopover?
    /// Requests typed but not sent, per file, until Crook quits.
    private var drafts: [String: String] = [:]
    /// The file whose checks are running. One start at a time.
    private var starting: URL?
    private var placements: [UUID: TerminalLauncher.Placement] = [:]
    private var nudgeUntil = Date.distantPast
    private var nudgeEnds: DispatchWorkItem?

    private static let startedOnceKey = "CrookClaudeStartedOnce"
    private static let startedCountKey = "CrookClaudeStartedCount"

    init(window wc: WorkspaceWindowController, registry: SessionRegistry = .shared) {
        self.wc = wc
        self.registry = registry
        super.init()
        accessory.layoutAttribute = .trailing
        wc.window?.addTitlebarAccessoryViewController(accessory)
        accessory.onClick = { [weak self] optionHeld in self?.buttonClicked(skipAsking: optionHeld) }
        registry.onChange = { [weak self] s in self?.sessionChanged(s) }
        registry.fileChanged = { s in Self.differsFromBaseline(s) }
        wc.editor.bridge.onReadOnlyAttempt = { [weak self] in self?.nudge() }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                                               name: NSWindow.didResizeNotification, object: wc.window)
        windowResized()
    }

    // MARK: - the open file

    private var document: CrookDocument? { wc.document as? CrookDocument }

    private func providerID(of doc: CrookDocument) -> String {
        doc.remoteProviderID ?? Providers.local.id
    }

    private func session(for doc: CrookDocument) -> ClaudeSession? {
        guard let url = doc.fileURL else { return nil }
        return registry.session(for: url.path, providerID: providerID(of: doc))
    }

    /// A session to watch or review for this file, on the machine the window
    /// is looking at.
    func hasSession(for url: URL) -> Bool {
        registry.session(for: url.path, providerID: Providers.current.id) != nil
    }

    /// Make the button, the banner and the editor agree with the open file.
    func refresh() {
        guard let doc = document, let url = doc.fileURL else {
            accessory.setMode(.hidden)
            wc.editor.setBanner(nil)
            wc.editor.bridge.setReadOnly(false)
            return
        }
        if starting == url {
            accessory.setMode(.opening)
            wc.editor.bridge.setReadOnly(true)
            wc.editor.setBanner(nil)
            return
        }
        let s = session(for: doc)
        switch s?.state {
        case .opening?: accessory.setMode(.opening)
        case .running?, .stopping?: accessory.setMode(.running)
        default: accessory.setMode(wc.fileVanished ? .disabled : .idle)
        }
        wc.editor.bridge.setReadOnly(s?.isLive == true)
        guard let s, let content = banner(for: s, doc: doc) else {
            wc.editor.setBanner(nil)
            return
        }
        wc.editor.setBanner(content,
                            onAction: { [weak self] action in self?.bannerAction(action) },
                            onOpenFile: { [weak self] relative in self?.openNearby(relative, from: s) })
    }

    private func banner(for s: ClaudeSession, doc: CrookDocument) -> BannerContent? {
        let current = doc.currentText()
        let baseline = s.baseline.flatMap { try? ByteCodec.decode($0).0 as String } ?? current
        let tally = SessionReview.tally(baseline: baseline, current: current)
        let provider = Providers.current
        let connected = provider.id == s.record.providerID && provider.isConnected
        // What is on screen, as bytes, when nothing is unsaved. Undo and Redo
        // are offered only while it is exactly the version they replace.
        let onScreen = doc.isDocumentEdited ? nil : try? wc.editor.bridge.data()
        let undo = SessionCopy.swapAvailability(verb: "undo", fileVanished: s.fileVanished, connected: connected,
                                                machine: s.record.machineName,
                                                diskMatches: onScreen != nil && onScreen == s.finalBytes)
        let redo = SessionCopy.swapAvailability(verb: "redo", fileVanished: s.fileVanished, connected: connected,
                                                machine: s.record.machineName,
                                                diskMatches: onScreen != nil && onScreen == s.baseline)
        let nearby = s.record.alsoChanged.map { SessionPlan.relativePath($0, from: s.record.workingDirectory) }
        return SessionCopy.banner(.init(state: s.state, added: tally.added, removed: tally.removed,
                                        fileVanished: s.fileVanished, machineName: s.record.machineName,
                                        nudging: Date() < nudgeUntil, undo: undo, redo: redo,
                                        alsoChanged: nearby))
    }

    // MARK: - starting

    private func buttonClicked(skipAsking: Bool) {
        guard let doc = document, doc.fileURL != nil, starting == nil else { return }
        if let s = session(for: doc), s.isLive {
            showTerminal()
            return
        }
        guard !wc.fileVanished else { return }
        wc.editor.bridge.selection { [weak self] anchor, head in
            guard let self, self.document === doc else { return }
            let lines = SessionPlan.selectedLines(in: self.wc.editor.bridge.text, anchor: anchor, head: head)
            if skipAsking {
                self.begin(doc, lines: lines, request: "")
            } else {
                self.ask(doc, lines: lines)
            }
        }
    }

    private func ask(_ doc: CrookDocument, lines: ClosedRange<Int>?) {
        guard let url = doc.fileURL else { return }
        popover?.close()
        let crumbs = Workspace.shared.breadcrumb(for: url)
        let defaults = UserDefaults.standard
        let context = AskPopover.Context(
            breadcrumb: crumbs.count > 1 ? crumbs.joined(separator: " ▸ ") : url.lastPathComponent,
            selectedLines: lines,
            machineName: doc.remoteProviderID == nil ? nil : Providers.current.displayName,
            showTip: lines == nil && defaults.integer(forKey: Self.startedCountKey) < 3,
            showFirstTime: !defaults.bool(forKey: Self.startedOnceKey),
            draft: drafts[url.path] ?? "")
        let question = AskPopover(context: context)
        question.onDraftChange = { [weak self] text in self?.drafts[url.path] = text }
        question.onOpen = { [weak self] request in
            guard let self else { return }
            self.drafts[url.path] = nil
            self.popover?.close()
            self.begin(doc, lines: lines, request: request)
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = question
        p.delegate = self
        p.show(relativeTo: accessory.anchor.bounds, of: accessory.anchor, preferredEdge: .minY)
        popover = p
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    /// The checks, in the order the spec gives them, stopping at the first that
    /// fails. The editor is read-only from here on, so nothing typed now can
    /// race the save Claude is about to read.
    private func begin(_ doc: CrookDocument, lines: ClosedRange<Int>?, request: String) {
        guard let url = doc.fileURL, starting == nil else { return }
        let provider = Providers.current
        guard providerID(of: doc) == provider.id else { return }
        wc.editor.dismissDiff()
        starting = url
        refresh()

        // 1. The file is still there.
        guard !wc.fileVanished, provider.exists(url.path) else {
            return fail(SessionCopy.vanished(fileName: url.lastPathComponent))
        }
        // 2. No conflict, or the person has chosen a version.
        resolveConflict(doc) { [weak self] proceed in
            guard let self else { return }
            guard proceed, self.document === doc else { return self.stopStarting() }
            // 3. The disk holds what the buffer holds. A failed save has already said why.
            guard doc.saveBeforeSession() else { return self.stopStarting() }
            self.wc.markEngaged()
            // 4. The machine is reachable.
            if !provider.isLocal && !provider.isConnected {
                return self.fail(SessionCopy.notConnected(machine: provider.displayName)) { [weak self] in
                    self?.wc.reconnect(to: provider.displayName)
                }
            }
            // 5. Claude Code is there, and new enough.
            let remote = provider as? RemoteProvider
            DispatchQueue.global(qos: .userInitiated).async {
                let result: ClaudePreflight.Result?
                if let remote {
                    result = ClaudePreflight.checkRemote(remote.transport)
                } else {
                    result = ClaudePreflight.checkLocal()
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.starting == url, self.document === doc else { return self.stopStarting() }
                    let machine = provider.isLocal ? nil : provider.displayName
                    switch result {
                    case .ready(let path, _)?:
                        self.launch(doc, url: url, provider: provider, claudePath: path, lines: lines, request: request)
                    case .missing?:
                        self.fail(SessionCopy.missing(machine: machine)) {
                            NSWorkspace.shared.open(SessionCopy.installURL)
                        }
                    case .tooOld(let version)?:
                        self.fail(SessionCopy.tooOld(machine: machine, installed: version)) { [weak self] in
                            self?.updateInTerminal(remote)
                        }
                    case nil:
                        self.fail(SessionCopy.notConnected(machine: provider.displayName)) { [weak self] in
                            self?.wc.reconnect(to: provider.displayName)
                        }
                    }
                }
            }
        }
    }

    private func stopStarting() {
        starting = nil
        refresh()
    }

    private func fail(_ alert: SessionCopy.Alert, onPrimary: (() -> Void)? = nil) {
        stopStarting()
        present(alert, onPrimary: onPrimary)
    }

    /// The disk changed while there were unsaved edits. Claude has to work on
    /// one version, and only the person can say which.
    private func resolveConflict(_ doc: CrookDocument, then done: @escaping (Bool) -> Void) {
        guard wc.hasConflict, let url = doc.fileURL else { return done(true) }
        let copy = SessionCopy.conflict(fileName: url.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        copy.buttons.forEach { alert.addButton(withTitle: $0) }
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                done(true)   // saveBeforeSession writes the buffer over the disk copy
            case .alertSecondButtonReturn:
                doc.reloadFromDiskDiscardingEdits(nil)
                done(true)
            default:
                done(false)
            }
        }
        if let w = wc.window { alert.beginSheetModal(for: w, completionHandler: decide) } else { decide(alert.runModal()) }
    }

    private func launch(_ doc: CrookDocument, url: URL, provider: FileProvider, claudePath: String,
                        lines: ClosedRange<Int>?, request: String) {
        guard let baseline = provider.contents(url.path) else {
            return fail(SessionCopy.vanished(fileName: url.lastPathComponent))
        }
        let roots = provider.isLocal
            ? Workspace.shared.importedURLs().map(\.path)
            : Workspace.importedPaths(forProviderID: provider.id)
        let machine = provider.isLocal ? nil : provider.displayName
        let id = UUID()
        let plan = SessionPlan.make(.init(filePath: url.path, projectRoots: roots, home: provider.homePath,
                                          machineName: machine, selectedLines: lines, request: request,
                                          voiceOver: NSWorkspace.shared.isVoiceOverEnabled, sessionID: id))

        // A new session supersedes a finished one's banner for the same file.
        for old in registry.sessions.filter({ !$0.isLive && $0.record.filePath == url.path
                                               && $0.record.providerID == provider.id }) {
            registry.discard(old)
        }
        let session: ClaudeSession
        do {
            session = try registry.begin(id: id, filePath: url.path, providerID: provider.id, machineName: machine,
                                         workingDirectory: plan.workingDirectory, baseline: baseline)
        } catch {
            return fail(SessionCopy.couldNotOpen(error.localizedDescription))
        }
        session.record.fingerprintsAtStart = fingerprints(under: plan.workingDirectory, excluding: url.path)

        let command: TerminalLauncher.Command
        if let remote = provider as? RemoteProvider {
            command = .remote(host: remote.transport.host, workingDirectory: plan.workingDirectory)
        } else {
            command = .local(workingDirectory: plan.workingDirectory, claudePath: claudePath)
        }

        arrangeWindow { [weak self] placement in
            guard let self else { return }
            session.record.crookFrameBefore = self.wc.window?.frame
            do {
                try TerminalLauncher.prepare(folder: session.folder, command: command,
                                             claudeArguments: plan.arguments, bounds: placement?.terminal,
                                             bundleID: Bundle.main.bundleIdentifier)
            } catch {
                self.registry.discard(session)
                return self.fail(SessionCopy.couldNotOpen(error.localizedDescription))
            }
            self.placements[session.id] = placement
            self.registry.save(session)
            self.starting = nil
            self.registry.watch(session)
            self.refresh()
            self.wc.rail.reload()
            TerminalLauncher.open(folder: session.folder) { [weak self] error in
                guard let self, let error else { return }
                self.registry.discard(session)
                self.refresh()
                self.present(SessionCopy.couldNotOpen(error.localizedDescription))
            }
        }
    }

    /// Leave full screen if Crook is in it — Terminal would open on another
    /// Space — then work out where Terminal goes.
    private func arrangeWindow(_ done: @escaping (TerminalLauncher.Placement?) -> Void) {
        guard let window = wc.window else { return done(nil) }
        guard window.styleMask.contains(.fullScreen) else { return done(placement()) }
        var observer: NSObjectProtocol?
        var finished = false
        let finish: () -> Void = { [weak self] in
            guard !finished else { return }
            finished = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            done(self?.placement())
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                          object: window, queue: .main) { _ in finish() }
        window.toggleFullScreen(nil)
        // If that notification never arrives, carry on rather than wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
    }

    private func placement() -> TerminalLauncher.Placement? {
        guard let window = wc.window, let screen = window.screen ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return nil }
        return TerminalLauncher.placement(crook: window.frame, visible: screen.visibleFrame,
                                          primaryHeight: primary.frame.height,
                                          crookMinWidth: window.minSize.width)
    }

    // MARK: - while it runs

    private func sessionChanged(_ s: ClaudeSession) {
        switch s.state {
        case .running where !s.handledStart:
            s.handledStart = true
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: Self.startedOnceKey)
            defaults.set(defaults.integer(forKey: Self.startedCountKey) + 1, forKey: Self.startedCountKey)
            if let p = placements[s.id], let crook = p.crook {
                makeRoom(for: s, crook: crook, terminal: p.terminal)
            }
            announce(SessionCopy.startedAnnouncement)
        case .ended(let outcome):
            placements[s.id] = nil
            ended(s, outcome: outcome)
        default:
            break
        }
        refresh()
        wc.rail.reload()
    }

    /// Move Crook aside only once Terminal is where it was asked to be. If it
    /// landed somewhere else, a narrowed Crook would be worse than overlap.
    private func makeRoom(for s: ClaudeSession, crook: CGRect, terminal: CGRect, attempts: Int = 15) {
        guard s.isLive, let window = wc.window else { return }
        let windowFile = s.file("window")
        guard let text = try? String(contentsOf: windowFile, encoding: .utf8) else {
            // The runner writes this a moment after it reports in.
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.makeRoom(for: s, crook: crook, terminal: terminal, attempts: attempts - 1)
            }
            return
        }
        // Empty: Terminal wouldn't say which window, so neither window moves.
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, s.isLive,
                  TerminalLauncher.landed(TerminalLauncher.frameOfWindow(number: number), near: terminal) else { return }
            window.setFrame(crook, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            s.record.crookFrameSet = window.frame
            self.registry.save(s)
        }
    }

    /// A write landed in the open file. True when the file is in watch mode and
    /// this has taken over highlighting it.
    func changeLanded(url: URL, before: String, after: String) -> Bool {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc), s.isLive else { return false }
        s.fileVanished = false
        let lines = SessionReview.changedLines(before: before, after: after)
        if let first = lines.first {
            wc.editor.bridge.pushChangedLines(lines)
            wc.editor.bridge.revealLine(first)
            announce(SessionCopy.changedAnnouncement(lines))
        }
        refresh()
        return true
    }

    func fileVanished(_ url: URL) {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc), s.isLive else { return }
        s.fileVanished = true
        refresh()
    }

    /// Someone tried to type while Claude has the file. Say why nothing
    /// happened, for four seconds, drawing the eye once.
    private func nudge() {
        guard let doc = document, session(for: doc)?.isLive == true else { return }
        if Date() >= nudgeUntil { wc.editor.pulseBanner() }
        nudgeUntil = Date().addingTimeInterval(4)
        refresh()
        nudgeEnds?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        nudgeEnds = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.05, execute: work)
    }

    private func showTerminal() {
        NSRunningApplication.runningApplications(withBundleIdentifier: TerminalLauncher.terminalBundleID)
            .first?.activate()
    }

    // MARK: - when it ends

    private func ended(_ s: ClaudeSession, outcome: SessionRunner.Outcome) {
        restoreFrame(s)
        let provider = Providers.current
        let here = provider.id == s.record.providerID
        let url = URL(fileURLWithPath: s.record.filePath)

        let protected = s.isRemote ? nil : SessionReview.protectedFolder(for: s.record.workingDirectory, home: Paths.home)
        if let alert = SessionCopy.alert(for: outcome, machine: s.record.machineName, protectedFolder: protected) {
            registry.discard(s)
            // A failure from before Crook last quit is not news worth a sheet.
            guard !s.endedWhileAway else { return }
            present(alert) { [weak self] in
                switch outcome {
                case .claudeMissing: NSWorkspace.shared.open(SessionCopy.installURL)
                case .folderAccess: NSWorkspace.shared.open(SessionCopy.privacyURL)
                case .closedWithoutChanges: self?.tryAgain(url)
                default: break
                }
            }
            return
        }

        if here && provider.isConnected {
            if let bytes = provider.contents(s.record.filePath) {
                try? bytes.write(to: s.file("final"), options: .atomic)
            } else {
                s.fileVanished = true
            }
            wc.rail.reload()
            s.record.alsoChanged = changedNearby(s)
        }
        registry.save(s)

        // A window closed during the session comes back on this file.
        if document == nil, here, !s.fileVanished, !s.endedWhileAway {
            wc.retarget(to: url)
        }
        if !s.endedWhileAway, let doc = document, doc.fileURL == url {
            let base = s.baseline.flatMap { try? ByteCodec.decode($0).0 as String } ?? ""
            let t = SessionReview.tally(baseline: base, current: doc.currentText())
            announce(SessionCopy.endedAnnouncement(added: t.added, removed: t.removed))
        }
    }

    private func tryAgain(_ url: URL) {
        guard let doc = document, doc.fileURL == url else { return }
        ask(doc, lines: nil)
    }

    /// Put Crook back, if it moved for Terminal and nobody has moved it since.
    private func restoreFrame(_ s: ClaudeSession) {
        guard let set = s.record.crookFrameSet, let before = s.record.crookFrameBefore,
              let window = wc.window, Self.roughlyEqual(window.frame, set) else { return }
        window.setFrame(before, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        s.record.crookFrameSet = nil
    }

    private static func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
            && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private func bannerAction(_ action: BannerContent.Action) {
        guard let doc = document, let s = session(for: doc) else { return }
        switch action {
        case .showTerminal: showTerminal()
        case .endSession: registry.requestEnd(s)
        case .review: wc.showChanges(nil)
        case .undo: swapVersions(s, doc: doc, restoring: true)
        case .redo: swapVersions(s, doc: doc, restoring: false)
        case .done:
            registry.discard(s)
            refresh()
        }
    }

    /// Undo puts the baseline back; Redo puts Claude's version back — each only
    /// if the disk still holds exactly the version it replaces.
    private func swapVersions(_ s: ClaudeSession, doc: CrookDocument, restoring: Bool) {
        let provider = Providers.current
        guard let outcome = s.outcome, provider.id == s.record.providerID, provider.isConnected,
              let baseline = s.baseline, let final = s.finalBytes else { return refresh() }
        let (expected, replacement) = restoring ? (final, baseline) : (baseline, final)
        do {
            guard try SessionReview.replace(path: s.record.filePath, on: provider,
                                            expecting: expected, with: replacement) else { return refresh() }
        } catch {
            wc.presentError(error)
            return
        }
        doc.reloadFromDisk()
        s.state = restoring ? .restored(outcome) : .ended(outcome)
        s.record.restored = restoring
        registry.save(s)
        refresh()
    }

    /// The person typed in a file. A finished session's banner has done its job.
    func userEdited(_ url: URL?) {
        guard let url, let doc = document, doc.fileURL == url,
              let s = session(for: doc), !s.isLive else { return }
        registry.discard(s)
        refresh()
    }

    /// What ⌘D compares against while a file has a session: everything Claude
    /// changed since it began, not since the file was last opened.
    func reviewBaseline(for url: URL) -> (text: String, title: String)? {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc),
              let data = s.baseline, let text = try? ByteCodec.decode(data).0 as String else { return nil }
        return (text, "Changes Claude made to \(url.lastPathComponent)")
    }

    // MARK: - menus

    func menuEditWithClaude() { buttonClicked(skipAsking: false) }
    func menuEditWithClaudeNow() { buttonClicked(skipAsking: true) }

    func menuEndSession() {
        guard let doc = document, let s = session(for: doc), s.state == .running else { return }
        registry.requestEnd(s)
    }

    func validate(_ item: NSMenuItem) -> Bool {
        let hasFile = document?.fileURL != nil
        let s = document.flatMap { session(for: $0) }
        let live = s?.isLive == true
        switch item.action {
        case #selector(WorkspaceWindowController.editWithClaude(_:)):
            item.title = live ? "Show Claude Session" : "Edit with Claude…"
            return hasFile && starting == nil && (live || !wc.fileVanished)
        case #selector(WorkspaceWindowController.editWithClaudeNow(_:)):
            return hasFile && starting == nil && !live && !wc.fileVanished
        case #selector(WorkspaceWindowController.endClaudeSession(_:)):
            return s?.state == .running
        default:
            return true
        }
    }

    // MARK: - helpers

    @objc private func windowResized() {
        accessory.setCompact((wc.window?.frame.width ?? 1000) < 900)
    }

    private func present(_ alert: SessionCopy.Alert, onPrimary: (() -> Void)? = nil) {
        let a = NSAlert()
        a.messageText = alert.title
        a.informativeText = alert.message
        alert.buttons.forEach { a.addButton(withTitle: $0) }
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn, alert.buttons.count > 1 { onPrimary?() }
        }
        if let w = wc.window, w.isVisible { a.beginSheetModal(for: w, completionHandler: handle) }
        else { handle(a.runModal()) }
    }

    private func announce(_ text: String) {
        guard !text.isEmpty, let window = wc.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func fingerprints(under folder: String, excluding path: String) -> [String: String] {
        let provider = Providers.current
        var out: [String: String] = [:]
        for file in Workspace.shared.filePaths(under: folder) where file != path {
            if let f = provider.fingerprint(file) { out[file] = "\(f.mtime):\(f.size)" }
        }
        return out
    }

    private func changedNearby(_ s: ClaudeSession) -> [String] {
        let now = fingerprints(under: s.record.workingDirectory, excluding: s.record.filePath)
        let before = s.record.fingerprintsAtStart
        return Set(now.keys).union(before.keys).filter { now[$0] != before[$0] }.sorted()
    }

    private func openNearby(_ relative: String, from s: ClaudeSession) {
        let path = (s.record.workingDirectory as NSString).appendingPathComponent(relative)
        wc.retarget(to: URL(fileURLWithPath: path))
    }

    /// Whether a session's file no longer holds its baseline. Unknown — the
    /// window looking at another machine — counts as changed, so the ending is
    /// a banner to review rather than an alert that might be wrong.
    private static func differsFromBaseline(_ s: ClaudeSession) -> Bool {
        let provider = Providers.current
        guard provider.id == s.record.providerID, let baseline = s.baseline,
              let now = provider.contents(s.record.filePath) else { return true }
        return now != baseline
    }

    /// `claude update`, in Terminal, on whichever Mac needs it. Not a session:
    /// nothing is watched, and the window stays open with the update's output.
    private func updateInTerminal(_ remote: RemoteProvider?) {
        let folder = registry.root.appendingPathComponent("update-\(UUID().uuidString.lowercased())", isDirectory: true)
        let home = remote?.homePath ?? Paths.home
        let command: TerminalLauncher.Command
        if let remote {
            command = .remote(host: remote.transport.host, workingDirectory: home)
        } else {
            let found = ClaudePreflight.knownLocations(home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
            command = .local(workingDirectory: home, claudePath: found ?? "claude")
        }
        do {
            try TerminalLauncher.prepare(folder: folder, command: command, claudeArguments: ["update"],
                                         bounds: nil, bundleID: nil, includeWindowScript: false)
        } catch {
            return present(SessionCopy.couldNotOpen(error.localizedDescription))
        }
        ClaudePreflight.forgetCachedInstall()
        TerminalLauncher.open(folder: folder) { _ in }
    }
}
```

- [ ] **Step 2: WorkspaceWindowController**

In `Crook/WorkspaceWindowController.swift`:

(a) Replace `private var syncState: SyncState = .inSync { didSet { refreshProxyIcon() } }` with:

```swift
    private var syncState: SyncState = .inSync { didSet { refreshProxyIcon(); sessions.refresh() } }

    var fileVanished: Bool { syncState == .vanished }
    var hasConflict: Bool { syncState == .conflict }

    /// Edit with Claude for this window. Created at the end of init, once the
    /// window and editor it attaches to exist.
    private(set) lazy var sessions = SessionController(window: self)
```

(b) In `init()`, replace the final `dumpViews()` with:

```swift
        _ = sessions
        dumpViews()
```

(c) In `syncTitle(_:)`, after `refreshReach()` at the end, add:

```swift
        sessions.refresh()
```

(d) In `handleExternalChange(_:)`, replace:

```swift
        if case .vanished = change {
            syncState = .vanished
```

with:

```swift
        if case .vanished = change {
            syncState = .vanished
            sessions.fileVanished(url)
```

and replace:

```swift
        if let d = LineDiff.between(before, after), !d.isEmpty {
```

with:

```swift
        if sessions.changeLanded(url: url, before: before, after: after) {
            // Watch mode highlights precisely; the proxy icon still carries
            // the net line change.
            lastDelta = LineDiff.between(before, after)?.delta ?? 0
        } else if let d = LineDiff.between(before, after), !d.isEmpty {
```

(e) In `showChanges(for:)`, after `if let expected, expected != url { return }`, add:

```swift
        if let review = sessions.reviewBaseline(for: url) {
            // The automatic diff on open is for changes made while you were
            // away; a file with a session has a banner saying that already.
            guard expected == nil else { return }
            let new = doc.currentText()
            guard review.text != new else { NSSound.beep(); return }
            editor.showDiff(old: review.text, new: new, title: review.title, since: nil)
            return
        }
```

(f) After `@objc private func document(_ doc: NSDocument, shouldClose: …) { … }`, add:

```swift
    // MARK: - Edit with Claude

    @objc func editWithClaude(_ sender: Any?) { sessions.menuEditWithClaude() }
    @objc func editWithClaudeNow(_ sender: Any?) { sessions.menuEditWithClaudeNow() }
    @objc func endClaudeSession(_ sender: Any?) { sessions.menuEndSession() }
```

(g) At the end of the file, add:

```swift
extension WorkspaceWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        sessions.validate(item)
    }
}
```

- [ ] **Step 3: CrookDocument**

In `Crook/CrookDocument.swift`, after the `saveRemote()` function, add:

```swift
    /// Put the buffer on disk before Claude reads the file. False when nothing
    /// was written, having already told the person why.
    ///
    /// A local document is written directly rather than through NSDocument's
    /// save: it is the same bytes the save would write, without AppKit's
    /// "changed by another application" sheet when the person has chosen
    /// their version over one on disk.
    func saveBeforeSession() -> Bool {
        guard isDocumentEdited else { return true }
        if remoteProviderID != nil {
            let outcome = saveRemote()
            if case .saved = outcome { return true }
            present(outcome)
            return false
        }
        guard let url = fileURL else { return false }
        do {
            let bytes = try data(ofType: fileType ?? "net.daringfireball.markdown")
            try Providers.local.write(bytes, to: url.path)
            // NSDocument compares this against the disk before its next save.
            fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            updateChangeCount(.changeCleared)
            SeenStore.shared.markSeen(url)
            return true
        } catch {
            presentError(error)
            return false
        }
    }
```

In `attach(to:)`, replace:

```swift
        editor.bridge.onEdit = { [weak self, weak editor] lowest in
            if lowest < Frontmatter.scanLimit { WorkspaceWindowController.shared.refreshReach() }
            self?.scheduleScan(editor)
        }
```

with:

```swift
        editor.bridge.onEdit = { [weak self, weak editor] lowest in
            if lowest < Frontmatter.scanLimit { WorkspaceWindowController.shared.refreshReach() }
            self?.scheduleScan(editor)
            WorkspaceWindowController.shared.sessions.userEdited(self?.fileURL)
        }
```

- [ ] **Step 4: Workspace**

In `Crook/Workspace/Workspace.swift`, before `// MARK: - imported projects (D-56: imported, never discovered)`, add:

```swift
    /// Every file in the tree at or below a folder. Edit with Claude uses it
    /// to notice which other files changed during a session.
    func filePaths(under folder: String) -> [String] {
        var out: [String] = []
        func walk(_ n: Node) {
            if n.kind == .file, let p = n.url?.path, p.hasPrefix(folder + "/") { out.append(p) }
            n.children.forEach(walk)
        }
        roots.forEach(walk)
        return out
    }
```

In `suggestions()`, directly after `let path = Self.decodeSlug(slug) ?? slug.replacingOccurrences(of: "-", with: "/")` inside the `compactMap`, add:

```swift
            // A session on a personal file runs in ~/.claude, and Claude Code
            // then lists that folder as a project. It is not one.
            guard path != claudeHome.path else { return nil }
```

- [ ] **Step 5: RailViewController — the sparkle**

In `Crook/Workspace/RailViewController.swift`, in `RailCell`, after `private let count = NSTextField(labelWithString: "")`, add:

```swift
    /// Shown instead of the count while this file has an Edit with Claude session.
    private let sessionMark = NSImageView()
```

In `init(id:)`, replace `addSubview(count)` with:

```swift
        addSubview(count)
        sessionMark.translatesAutoresizingMaskIntoConstraints = false
        sessionMark.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Editing with Claude")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                .applying(.init(paletteColors: [SessionBanner.changedYellow])))
        sessionMark.isHidden = true
        addSubview(sessionMark)
```

and add to its `NSLayoutConstraint.activate([...])`:

```swift
            sessionMark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sessionMark.centerYAnchor.constraint(equalTo: centerYAnchor),
```

At the end of `configure(_:)`, add:

```swift
        // A file Claude is editing right now, findable from anywhere in the tree.
        let editing = node.kind == .file && node.url.map {
            SessionRegistry.shared.liveSession(for: $0.path, providerID: Providers.current.id) != nil
        } == true
        sessionMark.isHidden = !editing
        if editing { count.stringValue = "" }
```

- [ ] **Step 6: AppDelegate — menu and reattach**

In `Crook/AppDelegate.swift`, `buildMenu()`, replace `fileMenu.addItem(reload)` with:

```swift
        fileMenu.addItem(reload)
        // Edit with Claude. The alternate replaces it while ⌥ is held and
        // skips the question.
        fileMenu.addItem(.separator())
        let claude = NSMenuItem(title: "Edit with Claude…",
                                action: #selector(WorkspaceWindowController.editWithClaude(_:)),
                                keyEquivalent: "e")
        claude.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(claude)
        let claudeNow = NSMenuItem(title: "Edit with Claude Now",
                                   action: #selector(WorkspaceWindowController.editWithClaudeNow(_:)),
                                   keyEquivalent: "e")
        claudeNow.keyEquivalentModifierMask = [.command, .shift, .option]
        claudeNow.isAlternate = true
        fileMenu.addItem(claudeNow)
        fileMenu.addItem(withTitle: "End Claude Session",
                         action: #selector(WorkspaceWindowController.endClaudeSession(_:)),
                         keyEquivalent: "")
```

In `applicationDidFinishLaunching(_:)`, directly before `// Reconnect to the machine this window was last looking at`, add:

```swift
        // Sessions from before Crook last quit: still running in Terminal, or
        // finished while Crook was closed and waiting to be reviewed. The
        // controller first, because it installs the callbacks reattach fires.
        _ = WorkspaceWindowController.shared.sessions
        SessionRegistry.shared.reattach()
        WorkspaceWindowController.shared.sessions.refresh()
```

- [ ] **Step 7: Build and run every suite**

Run: `./scripts/build.sh && ./scripts/test.sh`
Expected: "==> built build/Crook.app", then all suites pass with "0 failed".

- [ ] **Step 8: Commit**

```bash
git add Crook/Claude/SessionController.swift Crook/WorkspaceWindowController.swift Crook/CrookDocument.swift Crook/Workspace/Workspace.swift Crook/Workspace/RailViewController.swift Crook/AppDelegate.swift
git commit -m "Edit with Claude: the button, the checks, watch mode and the review"
```

---

### Task 9: Prove it end to end, document it, prepare the release

**Files:**
- Modify: `README.md`
- Modify: `scripts/build.sh` (version)
- Modify: `docs/superpowers/specs/2026-09-11-edit-with-claude-design.md` (record anything verification changed)

**Interfaces:**
- Consumes: the whole feature.
- Produces: a verified build, the docs, and version 0.3.0 ready to package. Publishing the GitHub release is **not** part of this task; it needs the owner's go-ahead.

- [ ] **Step 1: Run the full automated suite from a clean build**

Run: `rm -rf build && ./scripts/build.sh && ./scripts/test.sh`
Expected: every suite passes, "0 failed". Any skip should be a known one (a system-wide Claude Code install).

- [ ] **Step 2: End-to-end on this Mac, driven for real**

Build and launch: `./scripts/build.sh && open build/Crook.app`. Use a throwaway project, not a real one: `mkdir -p ~/Desktop/crook-e2e/.claude && printf '# E2E\n\nStep one.\nStep two.\n' > ~/Desktop/crook-e2e/CLAUDE.md`. Add it with **Add a Project…**. Then verify, noting each result:

1. The button shows at the trailing end of the title bar only when a file is open.
2. The popover shows the breadcrumb, the selection note for a selection, the tip without one, and the first-time line.
3. Return opens Terminal. The session folder appears under `~/Library/Caches/Crook/sessions/`. Claude's first message names the relative path and the request.
4. Terminal lands beside Crook. Check with the scratchpad `winlist` helper, or by eye. Crook narrows only when needed.
5. While running, typing in Crook does nothing and the banner nudges. Claude's edit reloads with precise highlights, and the tally updates.
6. `/exit`: Terminal closes, Crook comes forward, and the end banner shows the tally. Review Changes shows the diff. Undo restores exact bytes (`cmp` against a copy taken before). Redo restores Claude's version.
7. End Session from the banner stops a running session within 3 s.
8. Closing the Terminal window gives the end banner.
9. Decline the trust question in a fresh folder: the "closed without making changes" alert, and Try Again reopens the popover.
10. Quit Crook mid-session, relaunch, and the file is back in watch mode.

Where a step needs typing into Terminal and can't be scripted, run the interactive part through the pty driver from the spike (`scratchpad/spike/drive.py`) against the same arguments, and confirm the Crook side by observing the session folder, the window list and the file.

- [ ] **Step 3: End-to-end for another Mac, against a local sshd**

Crook's own ssh always reads `~/.ssh/config`, and the owner's config isn't to be edited, so the in-app remote flow can only run against a real reachable Mac. If `mac-mini` answers (`ssh -o BatchMode=yes mac-mini true`), repeat Step 2 there on a throwaway folder.

Either way, run the real remote runner through real ssh. Start the throwaway user-level sshd from the spike (`scratchpad/sshd`, port 2222, private key). Prepare a session folder with `TerminalLauncher.prepare(.remote(host: "crooktest", …))`, rewrite its `argv` with `-F <scratch ssh_config>` added after `-t`, and run `launch.command` in a pty with the real `claude` and a request that edits a scratch file. Verify:
- the file changes through ssh;
- ssh joins the control master without a key;
- the session survives killing another client of that master.

Stop the sshd and delete the scratch keys when done.

- [ ] **Step 4: README**

In `README.md`, after the `### Keyboard` table, add a `⇧⌘E | Edit with Claude` row to that table. Then insert this section before `---` / `## Working on another Mac`:

```markdown
### Editing with Claude

Some changes are easier to describe than to make: rename something that
appears in a dozen places, turn a section into a checklist, tighten a skill's
description. Click **Edit with Claude** at the top right of the window, or
press `⇧⌘E`.

Say what you want in the box that appears — or leave it empty — and press
Return. Crook opens Claude Code in Terminal, beside this window, already in the
right folder and already told which file you mean. If you selected some lines
first, it knows those too. Talk to Claude there. Every change it saves shows
up in Crook straight away, highlighted.

While Claude has the file it's read-only in Crook, so the two of you never type
over each other. When you're done, type `/exit` in Terminal. Crook comes back
to the front and says what changed: **Review Changes** shows the diff, and
**Undo Changes** puts the file back exactly as it was.

You need [Claude Code](https://code.claude.com/docs/en/setup) installed, and
Crook tells you if it isn't. The first time you use it in a folder, Claude Code
asks whether you trust that folder; choose **Yes, I trust this folder**. For a
file on another Mac, Claude runs on that Mac, over the connection Crook already
has.

Claude can change the open file without asking. If a change needs other files
too, Claude Code asks you before it touches each one.
```

- [ ] **Step 5: Version**

In `scripts/build.sh`, change `<key>CFBundleShortVersionString</key><string>0.2.0</string>` to `0.3.0`, and `<key>CFBundleVersion</key><string>2</string>` to `3`.

- [ ] **Step 6: Code review**

Use superpowers:requesting-code-review on the branch diff against `main`. Fix what it finds, worst first, re-running `./scripts/test.sh` after each fix.

- [ ] **Step 7: Package, and stop**

Run: `./scripts/release.sh`
Expected: `dist/Crook-0.3.0.zip`, with the signature verified on the extracted copy.

Commit:

```bash
git add README.md scripts/build.sh docs/superpowers/specs/2026-09-11-edit-with-claude-design.md
git commit -m "Crook 0.3.0: Edit with Claude"
```

Then report to the owner, and wait for their go-ahead before pushing the branch, merging, tagging `v0.3.0`, or attaching the zip to a GitHub release.

---

## Self-review

- **Spec coverage.**
  - §5.1 button, menu, ⌥ and sidebar: Tasks 7 and 8.
  - §5.2 popover: Task 7, plus `ask` in Task 8.
  - §5.3 checks: `begin` in Task 8, plus Task 3.
  - §5.4 placement: `TerminalLauncher.placement` and the runner (Task 2), `makeRoom` (Task 8).
  - §5.5 watch mode: Task 6, and `changeLanded` and `nudge` in Task 8.
  - §5.6 finishing: `ended`, the banners and `swapVersions` (Task 8), plus Task 5.
  - §5.7 restart: `reattach` (Task 4) and AppDelegate (Task 8).
  - §6 states: Tasks 4 and 5.
  - §7 remote: the runner (Task 2), `checkRemote` (Task 3), `connectionOptions`.
  - §8 accessibility: announcements, the flag, reduce motion and labels.
  - §9 alerts: Task 5.
  - §10: Task 1. §11: Tasks 2 and 4. §12: file map. §13: tests throughout, plus Task 9.
  - Gaps accepted: remote vanishing is detected when the session ends, not live, because the helper's change events don't carry deletions to `handleExternalChange`.
- **Placeholders.** None. Every code step carries its code.
- **Type consistency.**
  - `SessionRunner.Outcome` is used in `ClaudeSession.State` and `SessionCopy.alert(for:)`.
  - `BannerContent.Action` matches `SessionBanner.actions` and `bannerAction`.
  - `TerminalLauncher.prepare(...)` has the same signature in the tests, the controller and `updateInTerminal`.
  - `ClaudePreflight.checkLocal(home:loginShell:)` has the same defaults in the tests and the controller.
  - `SessionController.reviewBaseline(for:)` is used in `showChanges(for:)`.


---

## Deviations during execution

Recorded as they happened. The code is authoritative where it differs from the blocks above.

1. **`revealLine` became `scrollToLine` in `editor.js`.** `editor.js` already declares a `revealLine` decoration, and esbuild refused the duplicate. The Swift method is still `EditorBridge.revealLine(_:)`; only its call into the page changed.
2. **CF-14 added.** CF-09 and CF-10 skip on any Mac with a system-wide Claude Code (this one has `/opt/homebrew/bin/claude`). CF-14 exercises `ClaudePreflight.run`'s time limit directly, independent of where Claude Code is installed.
3. **Placement uses Terminal's `frame`, not `bounds`.** The first end-to-end run found that `bounds` shifted, or clamped onto the other display, a window that started on a secondary screen. `frame`, in AppKit global coordinates, was exact from either display. So:
   - `Placement.terminal` is in AppKit coordinates, and `placement(...)` lost its `primaryHeight` parameter;
   - `landed(_:near:primaryHeight:)` converts the window server's top-left frame;
   - `prepare(... frame:)` writes a `frame` file through `frameEdges(_:)`;
   - the runner sets `frame` twice, a second apart;
   - `confirmPlaced` looks up to four times;
   - CL-01 to CL-07 were rewritten for AppKit coordinates, and CL-08 was added.
4. **Frame restore after a restart.** Crook recentres its window at launch, so a reattached session compares only the size it set (`ClaudeSession.reattached`).
5. **End-to-end self-test.** It lives behind `#if CROOK_E2E` in `SessionController.swift`, with `CROOK_SWIFT_FLAGS` added to `build.sh` and `scripts/e2e-claude.py` as the driver. The shipped binary contains none of it (checked with `strings`). Results are in spec §14.1.
6. **Code review of the finished branch.** Fixed, with tests where the logic allows:
   - **Writes follow symlinks.** `LocalProvider.write` replaces the file a symlink resolves to, through a staging file and `replaceItemAt`, so `CLAUDE.md → AGENTS.md` stays a link and keeps its permissions and extended attributes (CV-28, CV-29).
   - **The checked `claude` is the one run.** The local runner runs the path the checks verified, falling back to PATH. The remote runner exports the login shell's PATH before `exec`, and both remote scripts read marked lines, so a talkative login script can't be taken for the answer. `zsh -f` everywhere, and `--` before the ssh host (CR-13, CR-23, CR-24).
   - **`finalBytes` means a version Crook saw.** It is written from the disk bytes of every change as it lands, and at the end only for a session Crook watched end. `swapAvailability` gained `haveVersion:` (CV-30).
   - **A failed Use Disk Version** shows `couldNotReadDisk` and cancels, instead of saving over the disk (CV-31).
   - **`saveBeforeSession`** flushes pending edits first.
   - **Which document is showing** is decided by `editor.owner`: `detachFromEditor` clears it, and `SessionController.document` requires it. The end-of-session retarget for a closed window was removed. `retarget(to:)` uses the same test, which fixes a bug from before this feature: after the red button, clicking the same file did nothing.
   - **`requestEnd`** signals `child.pid` only while its parent is the runner, else the runner once `isRunner` confirms it, and checks again before SIGKILL (CG-20). Failure alerts use `discard(_:deletingFolderAfter: 10)` (CG-21, CG-22).
   - **`EditorBridge.revealLine(_:)` became `reveal(lines:)`**, calling `scrollToLines`, which leaves the view alone if any changed line is visible or the reader scrolled by wheel, scroll bar or keys in the last 3 s. `changedAnnouncement` gives a range only for contiguous lines (CV-32, CV-33).
   - **`SessionBanner.apply`** updates its buttons in place when the actions and titles are unchanged. `ClaudeButton` sizes its container to fit.
   - **`ClaudePreflight.systemLocations`** is a variable, so CF-09 and CF-10 set this Mac's Homebrew install aside instead of skipping. The version check's time limit is 4 s.
   - **Not changed:** the reviewer read spec §10.1 as forbidding the home folder as a starting folder. The code starts in the file's own folder, which is home only for a file directly in it. The spec was corrected instead.
7. **Pre-release review and real-machine checks** (four reviewers plus checks S9 to S13; spec §14.0). Fixed, with tests:
   - **Permissions:**
     - `SessionPlan.preapprovalRule` became `preapprovalRules`, passed through `--settings` JSON (CP-30 to CP-32, CP-36);
     - `asksBeforeEditing` and honest approval wording (CP-33 to CP-35, CP-37, CP-38; CV-34, CV-35).
   - **Finding claude on this Mac:** every copy is considered, the login PATH is read from a marked line, and `--version` runs with a working PATH (CF-15 to CF-19).
   - **The far Mac:**
     - a `setsid` probe with a temp file and a group kill;
     - a marked `CROOK_EXE` line, plus an `env -0` block that is imported;
     - `crook_login_value` and `crook_apply_login_env` (CR-28 to CR-30; CF-13 now runs the probe).
   - **The local runner:** the `abandoned` re-check, `cd -- "$S" || exit 0`, the tty passed to the closer, `exit $st` after an error (CR-25 to CR-27). The closer also checks one tab, idle and the same tty.
   - **The registry:**
     - a tolerant `Record.init(from:)`;
     - on the start timeout, `runner.pid` is re-read, and a stand-down counts as didNotStart;
     - SIGCONT on End Session;
     - a delayed discard removes the record first;
     - `reattach` keeps live-runner folders and dates dead sessions by `lastActivity` (CG-23 to CG-28).
   - **The controller:**
     - `provider(for:)`, text-based Undo/Redo availability and alert A‑14;
     - drafts kept for Try Again, which A‑9 now offers too;
     - the popover identity guard;
     - the open-error guard, `fileReturned`, `isEditing`;
     - the nudge announcement;
     - frame restore only onto a screen;
     - focus after banner actions;
     - End Claude Session hidden unless live;
     - Esc for OK.
   - **The document and window:**
     - `fileModificationDate` refreshed on reload;
     - `diskChangedUnderEdits` in the conflict check;
     - Save disabled during a session;
     - a clean document closes with its window;
     - flush before the dirty check;
     - `FileWatcher` reports a file that returns.
   - **Writes:** `LocalProvider.write` refuses folders and restores the group and permissions. The agent writes through symlinks the same way, and `agentVersion` is now 2 (A-30, A-31).
   - **`UnifiedDiff`:** a Myers `editScript` past the LCS cell limit (U-10 to U-12, CV-36).
   - **UI:** the banner's title over its note, truncating also-changed links, compact yellow sparkles, popover accessibility and line height, the key-view loop, Tab not counted as typing, grey sidebar sparkles for sessions awaiting review, the slug guard for `~/.claude` suggestions.
   - **A second review of these fixes** found regressions, fixed with tests:
     - the agent refused writes in projects reached through a linked folder (A-32);
     - `diskModificationDate` must be the path's own date, as NSDocument keeps it, not the target's (CV-42);
     - read-only and array names in the far login environment ended the script, so they're skipped and the script's array is renamed `CROOK_FIELDS`;
     - `abandoned` only means didNotStart without a `child.pid` (CG-29);
     - the key-view loop is recalculated when banner buttons are rebuilt;
     - an installer-location copy with no version is retried with the shell's PATH (CF-20);
     - the closer compares the tty only when Terminal reports one.
   - **Found while checking it, from before this feature:** NSDocument couldn't save or autosave a symlinked document at all ("The file doesn't exist"). `writeSafely` now writes the linked file through `LocalProvider.write` for in-place saves (L-20 to L-23). `noteDiskUnchanged` keeps the date current when a file is rewritten with the bytes Crook already holds.
   - **Reported and not changed:**
     - remote reads on the main thread when a session ends, as elsewhere in Crook;
     - a remote file deleted during a session shows no "moved or deleted" banner;
     - an oh-my-zsh prompt can take Terminal's command (A‑9 with Try Again).
