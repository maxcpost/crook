# Edit with Claude — design spec

**Status:** Approved and implemented · 2026-09-11 (Crook 0.3.0)
**Feature:** A button that opens Claude Code in Terminal, already pointed at the file open in Crook, so a person can change the file by describing the change.
**Target:** Crook 0.3.0

---

## 1. Why

People like reading their Claude Code files in Crook. Some changes are big, though: renaming something that appears in a dozen places, or rewriting a whole section. People don't want to make those edits by hand. They want to say what they want and have Claude do it.

Crook already handles the second half of that. When Claude Code rewrites a file, Crook reloads it, highlights the lines that changed and shows the diff. The first half is missing: getting from "I'm looking at this file" to "Claude is working on this file and I can watch" in one step. Today that means opening Terminal, going to the right folder, starting `claude` and explaining which file you mean.

## 2. Who it's for, and what good looks like

The people it's for are the friends who download Crook from GitHub. Some of them work in Terminal every day. Some have barely opened it. All of them keep Claude Code files both on their own Mac and on another Mac they reach over SSH.

Good looks like this:

1. **Two actions.** From an open file, a person reaches a Claude Code session that already knows the file, and the lines they selected, with a click and then Return.
2. **No Terminal knowledge needed to start.** No `cd`, no typing `claude`, no paths.
3. **They can watch every change, and nothing competes for the file.** Each change appears in Crook as Claude saves it. The person can't accidentally type over Claude.
4. **They finish knowing what happened.** Crook says what changed, shows the diff, and can restore the file byte for byte.
5. **Problems are explained in Crook.** If Claude Code is missing or too old, the connection is down, or macOS is blocking a folder, Crook names the machine and the fix before a Terminal window opens, wherever that can be known in advance.
6. **Another Mac works the same way.** A file there gets the same flow, and nobody types a password a second time.
7. **No byte changes that the person didn't ask for,** and Crook still writes nothing into their projects.

## 3. Decisions already made

| Question | Decision | Why |
|---|---|---|
| Where the conversation happens | A Terminal window running Claude Code | It's the person's own Claude Code, it's the least new code, and it works over SSH without changes |
| What Claude may change | The open file without asking. Any other file only after Claude Code's own approval prompt | A rename that spans several files still works, and the person approves each extra file |
| Files on another Mac | Supported in the first version | Friends use Crook both locally and over SSH |
| Name | **Edit with Claude** | It opens Claude Code specifically, and only works if Claude Code is installed |

This spec made seven further decisions, listed in §15; all were approved with the spec.

## 4. Principles

All of these come from how Crook already works:

- **The file on disk is the file.** Crook shows Claude's changes. It doesn't merge them.
- **The buffer is never discarded silently.** Unsaved edits are saved, or the person chooses what to do with them, before Claude starts.
- **One writer at a time.** While Claude has the file, Crook shows it live and read-only.
- **Name the machine and name the fix.** Every message says which Mac it's about and what to do.
- **AppKit owns every control.** The web view gets no buttons. The banner and popover are native.
- **Crook writes nothing into projects.** Session files live in `~/Library/Caches/Crook/`.
- **Yellow means Claude.** Crook's single accent keeps its meaning: a highlighted line is one Claude changed.

---

## 5. The flow

The steps below happen in this order.

### 5.1 Finding it

**The title bar button.** It sits at the trailing end of the title bar as an `NSTitlebarAccessoryViewController`, so no toolbar comes back. It shows the `sparkles` symbol and the label **Edit with Claude**, in accessory-bar style so it weighs less visually than the title. Tooltip: "Describe a change and Claude Code makes it (⇧⌘E)".

| Situation | Button |
|---|---|
| No file open (empty state) | Hidden |
| Untitled document that has never been saved | Hidden |
| File open, clean or with unsaved edits | **Edit with Claude** |
| File no longer on disk (`.vanished`) | Disabled. Tooltip "This file is no longer on disk." |
| Session starting for this file | Spinner, **Opening…**, disabled |
| Session running for this file | Yellow dot, **Editing with Claude**. Clicking brings Terminal forward. |
| Window narrower than 900 pt | Symbol only. The label moves into the tooltip. |

**The menu.** File ▸ **Edit with Claude…** ⇧⌘E, directly below Reload from Disk. While this file has a session running, the item reads **Show Claude Session** with the same shortcut, and **End Claude Session** appears below it.

**Skipping the popover.** ⌥-clicking the button, or pressing ⌥⇧⌘E, opens the session straight away with no request.

**The sidebar.** While a file has a session running, a small yellow `sparkles` symbol appears where its change count normally sits. That keeps the session easy to find after navigating to other files.

### 5.2 Asking: the popover

Clicking the button opens a popover under it. Typing a request is optional. Return always opens the session.

```
┌────────────────────────────────────────────────────┐
│  System ▸ skills ▸ release-notes ▸ SKILL.md          │
│  Lines 12–16 selected                                │
│ ┌────────────────────────────────────────────────┐   │
│ │ Describe the change, or leave this empty to     │   │
│ │ talk it through                                 │   │
│ │                                                 │   │
│ └────────────────────────────────────────────────┘   │
│  Opens Claude Code in Terminal, beside this window.  │
│  Each change appears here as Claude saves it.        │
│                                 [ Open Claude Code ] │
└────────────────────────────────────────────────────┘
```

- **Context.** The first line is the breadcrumb from the window title. The second line depends on the selection:
  - with a selection: "Lines 12–30 selected" (or "Line 12 selected");
  - with no selection, for a person's first three sessions: "Tip: select part of the file first to point Claude at it.", in tertiary ink;
  - otherwise: no second line.
- **The request field.** Multi-line, three lines tall, growing to eight.
  - **Return** opens the session. **⇧Return** starts a new line. **Esc** closes the popover.
  - Closing keeps the draft for that file until Crook quits.
- **The footer.**
  - This Mac: "Opens Claude Code in Terminal, beside this window. Each change appears here as Claude saves it."
  - Another Mac: "Opens Claude Code on mac-mini, in Terminal beside this window. Each change appears here as Claude saves it."
- **First-time line.** Until a session has started once, one more line appears: "The first time, Claude Code may ask you to log in. In a folder it hasn't seen before, it asks whether you trust it: choose “Yes, I trust this folder”." That trust question defaults to **No, exit** (check S4), which is why the line names the choice to make.
- **The button.** **Open Claude Code**, the default button.

**Why a popover, instead of opening Terminal straight away:**
- It puts the first instruction, often the only one, in the app the person is already looking at, next to the selection it applies to.
- With a request typed, Claude starts working as soon as Terminal opens instead of greeting first.
- It's the one place the feature can explain itself without a one-time sheet.

An empty request still works, and ⌥-click skips the popover entirely.

### 5.3 Checks before Terminal opens

When the person presses Open, the popover closes, the button shows **Opening…** and the editor becomes read-only. Crook runs these checks in order and stops at the first failure:

1. **The file still exists.** If it disappeared since the popover opened: alert A‑7.
2. **There's no conflict.** If the file changed on disk while the person had unsaved edits (`.conflict`), Crook asks which version Claude should work on (alert A‑5).
   - **Use My Version** saves over the disk copy.
   - **Use Disk Version** takes the disk copy, the same as ⌘R.
   - **Cancel** stops here.
3. **Unsaved edits are saved.** A local file saves in place. A remote file goes through `saveRemote()`. If saving fails, Crook shows its existing save error and nothing opens.
4. **Crook is connected** (another Mac only). If not: alert A‑4, with a Reconnect button.
5. **Claude Code is installed, and new enough, on the Mac that holds the file.**
   - **This Mac:** Crook looks in the installer's known locations first, then asks the person's login shell, giving up after 3 s. It caches the result until Crook quits, and checks again if the cached path disappears.
   - **Another Mac:** one command over Crook's existing connection.
   - **Missing:** alert A‑1 or A‑2. **Too old:** alert A‑3, with an Update in Terminal button.

Checks take under 300 ms once Claude Code's location is cached, and at most 3 s. On any failure the editor becomes editable again and the button returns to idle.

When every check passes, Crook saves the **baseline**, the exact bytes on disk at that moment, and then opens Terminal.

### 5.4 Opening Terminal

**Where the Terminal window goes.** Crook places it beside Crook's window, with the same top edge and height. It uses the screen that holds most of Crook's window, and tries these in order:

1. If there's room on the right for a Terminal window at least 560 pt wide, Terminal goes there, up to 760 pt wide. Crook doesn't move.
2. Otherwise, if there's room on the left, Terminal goes there.
3. Otherwise, Crook narrows itself toward the left edge of the screen, never below its 720 pt minimum, and Terminal takes the right side. Crook remembers its previous frame so it can put it back later.
4. If Crook is in full screen, it leaves full screen first and then applies the rules above.

Window moves animate unless Reduce Motion is on.

How it's done (check S2): the runner inside the new Terminal window sets its own window's `frame` (AppKit global coordinates: left, bottom, right, top) through `osascript`, then sets it again a second later, because Terminal still repositions a brand-new window in that first moment. It uses `frame` rather than `bounds`: on a Mac with two displays, `bounds` is converted through whichever screen the window starts on, and landed windows on the wrong display. Terminal is then talking to itself, so macOS asks for no permission. Crook moves or narrows its own window only after it has read Terminal's actual frame back through `CGWindowListCopyWindowInfo` and found it where it asked. If Terminal isn't there, neither window moves. The runner leaves a window alone if it holds more than one tab, because the person's Terminal is set to open new work in tabs and that window isn't the runner's to move.

**What the person sees in Terminal:**

1. A new window titled **Crook: SKILL.md — release-notes**. This is Claude Code's session name.
2. For a file on another Mac: no password prompt, because `ssh` reuses Crook's open connection.
3. The first time in that folder: Claude Code asks whether to trust the folder. The first time using Claude Code at all: its login steps. Over SSH that's the paste-a-code login.
4. The first message, already sent (§10.3). For example: *In lines 12–16 of skills/release-notes/SKILL.md: turn Steps into a checklist and add a final read-through step.*
5. Claude responds:
   - with a request, it reads the file and starts editing;
   - without one, it describes the file in a sentence or two and asks what to change.

While Terminal starts, Crook's banner reads **Opening Claude Code in Terminal…** until the session reports that it's running, normally within a second of the Terminal window appearing. If that report doesn't arrive within 15 s, Crook shows alert A‑9 and the editor becomes editable again.

### 5.5 While Claude works: watch mode

While the session runs, Crook's editor shows the file live and read-only, with a banner across the top of the editor pane. The banner pushes the text down rather than covering it.

**The running banner:**

> ● **Editing with Claude in Terminal** · Read-only here until you finish  [Show Terminal] [End Session]

After Claude's first change, the note becomes **+12 −4 so far · read-only until you finish**.

**When a change lands:**

- **Reload.** Crook reloads through its existing path in `handleExternalChange`: the buffer is clean, so the file reloads, the caret and scroll position stay put, and the icon turns yellow.
- **Precise highlights.** Highlights mark only the lines that actually changed, computed with `UnifiedDiff` against the previous content. A rename that touches line 3 and line 80 highlights those two lines, not the 78 lines between them. This applies only during a session. Outside sessions, highlighting still uses `LineDiff`.
- **Scrolling.** If none of the changed lines are visible, the editor scrolls so the first one sits a third of the way down. If the person scrolled within the last 3 s, Crook leaves their position alone. The tally in the banner still updates.
- **The tally.** Lines added and removed, counted against the baseline.
- **VoiceOver** announces "Claude changed lines 12 to 18."
- **⌘D** (Show Changes) shows the diff against the baseline, meaning everything Claude has changed this session.

**If the person tries to type** (a character, Delete, a paste, or dictation), nothing changes in the file. The banner briefly brightens and its note reads **To edit it yourself, finish in Terminal or click End Session** for 4 seconds. Selecting, copying, scrolling and zooming all keep working.

**Moving to another file and back.** Other files open and edit normally. Returning to the session's file puts it back in watch mode. The automatic "changed since you last opened it" diff doesn't appear for a file with a running session or a pending review, since the banner covers that.

**If Claude moves or deletes the file,** the banner changes to:

> **Claude moved or deleted this file** · The sidebar shows what's there now  [Show Terminal] [End Session]

**Show Terminal** brings Terminal forward.

**End Session** stops Claude Code immediately, with no confirmation (§11.6). Changes already saved stay, and the next banner offers Undo.

### 5.6 Finishing

| How the session ends | Terminal | Crook |
|---|---|---|
| The person types `/exit` (or presses Ctrl‑D, or Ctrl‑C twice) | The window closes, and Crook comes forward | End banner |
| The person clicks **End Session** | The window closes | End banner |
| The person closes the Terminal window | Terminal asks whether to terminate, then closes | End banner. Crook doesn't come forward. |
| The connection to the other Mac drops | The window stays open, showing ssh's message | Lost-connection banner |
| Claude Code exits with an error | The window stays open so the error can be read | "Claude Code stopped unexpectedly" banner |

Closing the Terminal window automatically depends on check S3. If that fails, the window stays open and its last line reads "Done. You can close this window; your changes are in Crook."

**Then Crook:**
1. leaves watch mode, so the editor is editable again;
2. restores its window frame, if it moved and the person hasn't moved or resized it since. For a session picked up after Crook restarted, only the size is compared, because Crook recentres its window at launch;
3. refreshes the sidebar;
4. shows the end banner.

**End banner, file changed:**

> ✓ **Finished editing with Claude** · +14 −6 in this file  [Review Changes] [Undo Changes] [Done]
> Also changed during the session: CLAUDE.md, commands/ship.md

The "Also changed" line lists other files in the same project, or in `~/.claude`, whose size or modification time changed during the session. Each name opens that file. After three names it reads "and 2 more". It says *during the session*, not "Claude changed", because something else may have written them.

**End banner, file not changed:**

> **Finished editing with Claude** · This file wasn't changed  [Done]

**End banner, connection lost:**

> **The connection to mac-mini closed, which ended the session** · +3 −1 saved before it closed  [Review Changes] [Done]

Undo becomes available after reconnecting.

**End banner, Claude Code stopped with an error:**

> **Claude Code stopped unexpectedly** · +3 −1 saved before it stopped  [Review Changes] [Undo Changes] [Done]

**Review Changes** (⌘D) opens Crook's existing change view, comparing the baseline with the file now. Its header reads **Changes Claude made to SKILL.md — 14 added, 6 removed**.

**Undo Changes** writes the baseline bytes back exactly. The banner becomes:

> **Restored the version from before Claude's changes**  [Redo Changes] [Done]

**Redo Changes** writes the session's final bytes back.

Undo and Redo are each offered only while the file on disk still matches what they would replace. Otherwise the button is disabled, with the tooltip "This file has changed since the session ended." Undo is never offered for a file that was moved or deleted, because writing the old path back would create a duplicate.

**How long the end banner stays.** Until the person clicks **Done**, types in the file, or starts another session on it. It stays across moving to other files and back, and across quitting and reopening Crook.

### 5.7 Crook quits or restarts during a session

The session keeps running, because it belongs to Terminal, not to Crook.

When Crook next launches, it looks for sessions that are still running. It confirms each process is the one Crook started, not a reused process ID, and puts those files back in watch mode. A session that ended while Crook was closed shows its end banner when its file is next opened.

If Crook's window is closed when a session ends, bringing Crook forward reopens the window on that file.

---

## 6. States

### 6.1 A session's life

```
            Open                 checks pass              runner reports start
  idle ───────────▶ checking ─────────────▶ opening ─────────────────────▶ running
   ▲                   │ fails                 │ 15 s, no report              │   │
   │                   ▼                       ▼                              │   │ End Session
   │                 idle + alert            idle + alert                     │   ▼
   │                                                                          │ stopping
   │                                                            process exits │   │ process exits
   │          Done, typing, or a new session                                  ▼   ▼
   └────────────────────────────────────────────────────────────────────── ended
                                                                   Undo ▲│    │▼ Undo
                                                                        │└ restored
                                                                        └──── Redo
```

### 6.2 When the editor is read-only

Read-only in **checking**, **opening**, **running** and **stopping**. Editable in every other state.

### 6.3 Banner and button in each state

| State | Button | Banner |
|---|---|---|
| idle | Edit with Claude | none |
| checking | Opening… | none |
| opening | Opening… | Opening Claude Code in Terminal… |
| running | ● Editing with Claude | Editing with Claude in Terminal · Read-only here until you finish, or +N −M so far |
| running, file gone | ● Editing with Claude | Claude moved or deleted this file |
| stopping | ● Editing with Claude | Ending the session… |
| ended | Edit with Claude | Finished editing with Claude, or the lost-connection or stopped-unexpectedly wording |
| restored | Edit with Claude | Restored the version from before Claude's changes |

---

## 7. Files on another Mac

Only the differences from a local file:

- **Where Claude runs.** On the Mac that holds the file, in that Mac's copy of the project folder.
- **Checks.** Claude Code is checked on that Mac, over Crook's connection.
- **Terminal's ssh** uses the same connection-sharing options as Crook, with the same control path. That lets it join the connection Crook already authenticated, so no password is needed. If that connection has lapsed, ssh asks for a password in Terminal the way ssh normally does.
- **The session outlives Crook's connection.** Crook switching machines, disconnecting or quitting doesn't end the session, because the shared connection stays open as long as Terminal is using it. That depends on check S6.
- **Change reporting.** Changes arrive through the helper's change events, as they do today.
- **Undo and Redo** need the connection. While disconnected they're disabled, with the tooltip "Reconnect to mac-mini to undo."
- **Naming.** The session name and the popover footer both name the machine.

## 8. Accessibility and motion

- **Labels.** The button, the popover field and the banner buttons all have accessibility labels. The banner is an accessibility group labelled with its text.
- **Announcements.** VoiceOver announces the session starting, each change with its line numbers, and the session ending with its counts.
- **Screen reader mode.** When VoiceOver is on, Claude Code starts with `--ax-screen-reader`.
- **Reduce Motion.** Windows move without animation, and the banner changes its text without brightening.
- **Keyboard.** Every action works from the keyboard: ⇧⌘E, ⌥⇧⌘E, Return, Esc and ⌘D. The banner buttons are in the key-view loop.

---

## 9. When things go wrong

### 9.1 Alerts

Alerts appear as sheets on Crook's window.

| # | When | Title | Message | Buttons |
|---|---|---|---|---|
| A‑1 | Claude Code isn't installed on this Mac | Claude Code isn't installed on this Mac. | Edit with Claude opens Claude Code, which isn't installed here yet. Install it, then try again. | How to Install · OK |
| A‑2 | Claude Code isn't installed on the other Mac | Claude Code isn't installed on mac-mini. | Claude works on the Mac where the file lives. Install Claude Code on mac-mini, then try again. | How to Install · OK |
| A‑3 | Claude Code is older than the minimum | Claude Code on this Mac needs an update. | Edit with Claude needs version {minimum} or later. This Mac has {installed}. | Update in Terminal · Cancel |
| A‑4 | Not connected to the file's Mac | Crook isn't connected to mac-mini. | Reconnect to open Claude Code there. Your file hasn't changed. | Reconnect · Cancel |
| A‑5 | The file changed on disk while the person was editing | SKILL.md changed on disk while you were editing. | Choose the version Claude should work on. | Use My Version · Use Disk Version · Cancel |
| A‑6 | Saving before the session failed | Crook's existing save error | | |
| A‑7 | The file disappeared before the session started | SKILL.md is no longer on disk. | It may have been moved or deleted. | OK |
| A‑8 | macOS blocked Terminal from the folder | Terminal can't open the folder this file is in. | macOS hasn't given Terminal access to your Desktop folder. Turn it on in System Settings, then try again. | Open Privacy Settings · OK |
| A‑9 | The session didn't report starting within 15 s | Claude Code didn't start. | If a Terminal window opened, it shows what went wrong. | OK |
| A‑10 | Claude Code exited with an error without changing the file. Declining the trust question does exactly this: it exits with 1 in under a second (check S4). | Claude Code closed without making changes. | If it asked whether to trust this folder, try again and choose “Yes, I trust this folder”. Otherwise, Terminal shows what went wrong. | Try Again · OK |
| A‑11 | The project folder is missing | The folder for this file is missing on mac-mini. (For this Mac: The folder for this file is missing.) | Claude Code needs to start in that folder. It may have been moved or renamed. | OK |
| A‑12 | Terminal's ssh failed within 10 s | Couldn't reach mac-mini from Terminal. | ssh reported a problem, and Terminal shows what it said. Check that Crook is still connected, then try again. | OK |

On A‑3 and A‑4, "this Mac" and "mac-mini" become whichever machine holds the file. A‑8 names the protected folder: Desktop, Documents or Downloads.

- **How to Install** opens Claude Code's setup page.
- **Update in Terminal** opens Terminal running `claude update`, over ssh for another Mac. It doesn't start watch mode.
- **Open Privacy Settings** opens System Settings ▸ Privacy & Security ▸ Files and Folders.

### 9.2 Edge cases

| Situation | What happens |
|---|---|
| Sessions on two different files | Allowed. Each has its own Terminal window, banner and sidebar symbol. |
| The button is clicked for a file whose session is running | Brings Terminal forward. |
| The person edits a different file that Claude is also changing | Crook's existing conflict handling applies. Only the session's own file is read-only. |
| Crook's window is closed during a session | The session continues. The window reopens on that file when the session ends. |
| The screen is too narrow for both windows (under 1280 pt) | Crook narrows to 720 pt and Terminal overlaps its right edge. |
| The change view is open when a session starts | It closes first. |
| The file path contains `* ? [ ] { }` | No pre-approval rule is passed, so Claude Code asks before editing this file too. Everything else works the same. |
| A session for a personal file | Runs in `~/.claude`. Claude Code then records that folder as a project, so Crook's project suggestions leave `~/.claude` out. |
| The person uses Claude Code's own `/rewind` (Esc Esc) | Works as normal. Crook's Undo covers the whole session for this file. |
| Claude Code is offline, rate-limited or logged out mid-session | Claude Code's own messages appear in Terminal. Crook stays in watch mode until the session exits. |
| Another app is the default for `.command` files | Crook always opens Terminal explicitly, so that setting doesn't matter. |
| The Mac restarts and a session's process ID is reused | Crook records each process's start time. If it doesn't match, the session counts as ended. |
| Files that may contain secrets (`.mcp.json`, `settings.local.json`) | No special handling. Claude Code reads them the way it reads any file. |

---

## 10. What Claude is told

### 10.1 Working folder

| File | Folder Claude Code starts in |
|---|---|
| Inside a project in the sidebar | That project's root. The longest matching root wins when projects are nested. |
| Inside that machine's `~/.claude` | `~/.claude` |
| Anywhere else | The file's own folder |

Crook never uses the home folder itself as the starting folder. Claude Code can't remember trust for the home folder, so it would ask every time.

### 10.2 The command

```
claude
  --session-id <uuid>
  --name "Crook: SKILL.md — release-notes"
  --permission-mode default
  --allowedTools "Edit(//Users/alice/atlas/.claude/skills/release-notes/SKILL.md)"
  --append-system-prompt "<§10.4>"
  [--ax-screen-reader]
  -- "<first message>"
```

- **`--permission-mode default`.** This is the ask-first mode. Version 2.1.268 lists it as `manual`, but it still accepts `default`, the name older versions also know, and the two behave identically (check S4). Crook passes it explicitly so that someone whose own default is `acceptEdits`, `auto` or `bypassPermissions` still gets asked before Claude edits any other file in this session. Check S4 confirmed that a command-line flag overrides a project's `acceptEdits` for that session.
- **The pre-approval rule.** One `Edit(//absolute path)` rule. The `//` anchors the path at the root of the filesystem. Edit rules cover every tool that edits files. The rule is left out when the path contains glob characters.
- **Argument order.** `--allowedTools` accepts any number of values, so the first message must come after `--` or it would be read as another tool. The tests pin this order.
- **The session name** is built as follows:
  1. start with the file name;
  2. if the name is a common one (CLAUDE.md, SKILL.md, AGENTS.md, README.md, settings.json, settings.local.json, .mcp.json), add " — " and the folder it's in;
  3. for another Mac, add " on {machine}";
  4. if the result is over 60 characters, shorten it in the middle.
- **Everything else is the person's own:** model, effort, MCP servers, hooks and plugins. Crook overrides none of them.

### 10.3 The first message

This appears in Terminal as the person's own message. The path is relative to the working folder.

| Request typed | Selection | Message |
|---|---|---|
| No | No | I'd like to make some changes to .claude/skills/release-notes/SKILL.md. |
| No | Yes | I'd like to change lines 12–30 of .claude/skills/release-notes/SKILL.md. |
| Yes | No | In .claude/skills/release-notes/SKILL.md: {request} |
| Yes | Yes | In lines 12–30 of .claude/skills/release-notes/SKILL.md: {request} |

**Which lines a selection covers.** The lines containing the start and end of the selection. If the selection ends at the very beginning of a line, that line isn't included. A caret with nothing selected counts as no selection. Offsets are UTF‑16, the same in CodeMirror and in `NSString`. The buffer only uses LF line endings, so the line numbers match the file whatever line endings it has on disk.

### 10.4 Appended system prompt

```
This session was opened from Crook, a Mac app for reading and editing the files
that configure Claude Code. The person is working on one file:

  {absolute path}
  {if selection: They selected lines {a}–{b} before opening this session.}

How to work with them:
- Crook shows this file live and highlights each change as you save it. Crook
  keeps the file read-only while this session is open, so you are the only one
  editing it.
- Edits to this file are already approved. Change what they ask for and nothing
  else.
- Keep everything you weren't asked to change exactly as it is: line endings,
  indentation, trailing whitespace, blank lines, the final newline, and
  frontmatter fields.
- If their request also needs other files changed (a skill folder renamed, a
  reference in another CLAUDE.md, a command that points at this file), say which
  files and why before editing them. Claude Code will ask them to approve each
  one.
- If their first message doesn't say what to change, read the file and reply in
  one or two sentences: what the file is for, then ask what they'd like to
  change. Don't edit anything until they ask.
- After your first change, tell them once, in one short line, that they can
  type /exit when they're finished to go back to Crook.
- They may not be technical. Use plain words, keep replies short, and describe
  changes by what they do rather than as diffs.
```

---

## 11. How the launch works

### 11.1 The session folder

Each session gets `~/Library/Caches/Crook/sessions/<uuid>/`, with permissions 0700. It goes in Caches for two reasons: the contents are disposable session state, and the path has no spaces, which keeps the runner simple. Crook's ssh control socket already lives under `Caches/Crook/` for the same reason. It's never inside a project.

| File | Written by | Holds |
|---|---|---|
| `session.json` | Crook | File path, machine id and name, working folder, start time, Crook's window frame before and after making room, the nearby files' fingerprints, and the outcome |
| `frame` | Crook | Where Terminal should go: left, bottom, right, top, in AppKit global coordinates |
| `baseline` | Crook | The file's exact bytes at the start |
| `final` | Crook | The file's exact bytes at the end, for Redo |
| `payload` | Crook | The argument lists, separated by NUL characters |
| `launch.command` | Crook | The runner. The same static text every time. |
| `runner.pid`, `child.pid` | Runner | Process IDs and process start times |
| `exit` | Runner | Exit status and reason |

The folder is deleted when the person clicks Done, or 7 days after the session ended.

### 11.2 Opening Terminal

Crook calls `NSWorkspace.open(_:withApplicationAt:configuration:)` with `launch.command` and Terminal (`com.apple.Terminal`). This is a Launch Services open, not an Apple Event. So there's no "Crook wants to control Terminal" prompt, and no `NSAppleEventsUsageDescription` is needed. It's always Terminal, whatever app is set to open `.command` files.

### 11.3 The runner

One static zsh script, identical for every session. It:

1. **Records itself.** It finds its session folder from its own path and writes its process ID to `runner.pid`. When Crook reattaches after a restart, it identifies the runner by that process's arguments (`sysctl KERN_PROCARGS2`), which name this session's `launch.command`. A reused process ID can't match that.
2. **Places its window.** It asks Terminal, through `osascript` and `window.applescript`, for the ID of the window whose busy tab is on its own tty, and writes that ID to `window`. If Crook asked for a position, it sets that window's `frame` twice, a second apart (check S2). A window with more than one tab is left alone. The AppleScript window ID is the same number `CGWindowListCopyWindowInfo` reports, which is how Crook confirms the move landed.
3. **Gets ready to run Claude Code.**
   - **This Mac:** it changes into the working folder and lists it, which is where a macOS folder permission denial shows up (exit reason `folder-access`). It then finds `claude` on the person's own PATH, which comes from the login shell Terminal started. If that fails, it uses the path Crook found during the checks.
   - **Another Mac:** it runs `/usr/bin/ssh -t <Crook's connection options> <host> <remote command>`.
4. **Starts Claude Code, or ssh, in the foreground** through `/bin/zsh -c 'print $$ > …/child.pid; exec "$@"' crook <argv>`. That records the process Crook will signal for End Session, and passes the arguments as arguments, never as code.
5. **Reports the exit.** After that process exits, it writes `exit` as "status seconds".
   - After End Session, it closes its own window.
   - After a clean exit (0 or 130), or its own failure (90–92), it brings Crook forward with `open -b` and closes its window. The close is a detached `osascript … close-when-idle`, started through `perl -MPOSIX -e 'setsid()…'` so it isn't counted as a process running in the window. It waits until the tab is no longer busy, then closes the window by ID, with no prompt (check S3).
   - Otherwise it leaves the window open, with a final line, so the error can be read.

**The quoting rule.** Text from a file name, a path, a machine name or a person's request is never put into shell source code.

- **This Mac:** the runner reads `payload` and splits it on NUL characters.
- **Another Mac:** the ssh command is a fixed template containing two base64 tokens, whose alphabet is only letters, digits, `+`, `/` and `=`. It runs through `/bin/sh -c '…'`, so it parses identically whether the other Mac's login shell is zsh, bash, fish or tcsh:

```
/bin/sh -c 'exec /bin/zsh -c "$(printf %s SCRIPT_B64 | base64 -D)" crook PAYLOAD_B64'
```

The decoded script is the static remote runner, and the payload is only data.

### 11.4 The remote runner

A static zsh script following the same quoting rule. It:
1. decodes the payload;
2. changes into the working folder, or exits with 91 if the folder is missing;
3. finds `claude` using that Mac's login shell (`$SHELL -lic 'command -v claude'`), then falls back to `~/.local/bin/claude`, `/opt/homebrew/bin/claude` and `/usr/local/bin/claude`, or exits with 90 if none exist;
4. runs Claude Code in that login shell's environment, passing the arguments as arguments.

### 11.5 Tracking the session

- **Start.** Crook watches the session folder. When `runner.pid` appears, the session is **running**.
- **End.** Crook watches the runner's process with a process-exit dispatch source, then reads `exit`. If there's no `exit` file, the Terminal window was closed.
- **Exit reasons.**

Rows are checked from top to bottom, and the first match wins:

| Runner reports | Outcome |
|---|---|
| Crook sent End Session, whatever the status | Finished |
| 0, or 130 (Ctrl‑C) | Finished |
| No `exit` file, meaning the Terminal window was closed | Finished |
| 90 | Claude Code missing (A‑1 or A‑2) |
| 91 | Folder missing (A‑11) |
| 92 | Folder access denied (A‑8) |
| ssh 255 within 10 s | Couldn't connect (A‑12) |
| ssh 255 later | Connection lost (lost-connection banner) |
| Any other non-zero, with the file unchanged since the baseline | Closed without making changes (A‑10) |
| Any other non-zero | Stopped unexpectedly |
| No runner report within 15 s of opening Terminal | Didn't start (A‑9) |

- **Reattaching.** On launch, Crook reattaches every session folder whose `runner.pid` names a live process with a matching start time.

### 11.6 End Session

Crook sends SIGTERM to the process in `child.pid`. That's Claude Code on this Mac, or ssh for another Mac, where ssh exiting hangs up Claude Code on the far side. If the process is still alive after 3 s, Crook sends SIGKILL. The fallback is required: during the spike, Claude Code sitting at its trust question ignored SIGTERM (check S5).

### 11.7 Connection options

`SSHTransport` exposes its list of connection options, and the runner's ssh uses exactly that list: the same ControlMaster, ControlPath, ControlPersist, ServerAlive and StrictHostKeyChecking values. If the runner kept its own copy and the two drifted apart, it would silently cost a second password.

---

## 12. Architecture

New code goes in a new folder, `Crook/Claude/`:

| Unit | What it does | Depends on |
|---|---|---|
| `SessionPlan` | Pure logic. From the file, roots, home, machine, selection lines, request and VoiceOver state, produces the working folder, argument list, first message, system prompt, session name and pre-approval rule. | Nothing; the roots are passed in |
| `SessionRunner` | Pure logic. Holds the static local and remote runner scripts, encodes the payload, builds the remote command template and maps exit reasons. | Nothing |
| `ClaudePreflight` | Finds Claude Code and its version on this Mac, or over the connection. | One-shot command in `SSHTransport` |
| `TerminalLauncher` | Writes the session folder, works out window placement and opens Terminal. | `NSWorkspace`, `SessionRunner` |
| `SessionRegistry` | Knows every session. Watches for start and exit, saves and reattaches sessions, sends End Session signals and cleans up. | The session folders |
| `SessionController` | Connects everything for the window: button state, popover, the order of checks, watch mode, banners, review, Undo and Redo, window placement. `WorkspaceWindowController` owns it, so that already-large file doesn't grow. | All of the above, `CrookDocument`, `EditorViewController` |
| `ClaudeButton` | The title bar accessory. | Nothing |
| `AskPopover` | The popover. | Nothing |
| `SessionBanner` | The banner view and its states. | Nothing |

Changes to existing code:

- **`editor.js` and `EditorBridge`:**
  - `setReadOnly(Bool)`, using a CodeMirror compartment around `EditorState.readOnly`;
  - `revealLine(n)`;
  - a `readOnlyAttempt` message;
  - `selectionLines()`.
- **`EditorViewController`** hosts the banner above the web view, pushing the text down.
- **`WorkspaceWindowController`:**
  - owns the `SessionController`;
  - exposes its sync state;
  - `handleExternalChange` uses precise highlights during a session;
  - `showChanges` skips the automatic diff for a file with a session.
- **`CrookDocument`** gets `saveBeforeSession(completion:)`, covering local and remote files.
- **`DiffOverlay`** takes the header wording as a parameter.
- **`Workspace`** gets `projectRoot(containing:)`, and `suggestions()` leaves out `~/.claude`.
- **`SSHTransport`** exposes its connection option list, plus a one-shot command for the checks.
- **`RailViewController`** draws the session symbol.
- **`AppDelegate`** adds the menu items, and reattaches running sessions at launch.
- **`scripts/test.sh`** picks up the new suites.

---

## 13. Testing

New suites run in Crook's existing harness (`./scripts/test.sh <suite>`).

- **`claude-plan`**
  - The working folder for a project file, a file in a nested project, a personal file, a file outside every project, and a file on another Mac.
  - Relative paths.
  - All four first-message forms.
  - Selection-to-line conversion: a caret only, a selection ending at the start of a line, emoji before the selection.
  - Paths with glob characters leave out the pre-approval rule.
  - The argument order, with the first message after `--`.
  - `--ax-screen-reader` on and off.
  - Session names, including shortening in the middle.
- **`claude-runner`**
  - Runs the real runner with a stub `claude` placed first on PATH. The stub writes out its arguments (NUL-separated) and its working folder.
  - Hostile inputs: spaces, `'`, `"`, `$(…)`, backticks, `;`, newlines, glob characters, non-ASCII text, a leading `-`, and a 100 KB request. The arguments must arrive byte for byte.
  - The remote path, using a stub `ssh`. The stub checks for `-t` and the exact connection options, then runs the remote command string locally through `/bin/sh -c`. This follows the existing agent tests: the full contract, without needing a second Mac.
  - Exit reasons 90, 91 and 92, plus an early non-zero exit.
- **`claude-registry`**
  - Detects a session starting, and detects it exiting using a real child process.
  - Rejects a reused process ID when the start time doesn't match.
  - Reattaches from a session folder.
  - End Session signals the child process.
  - Cleanup after Done and after 7 days.
- **`claude-review`**
  - Tally counts.
  - Undo and Redo write exact bytes for CRLF files, files without a final newline, and files with a byte-order mark. Tested through `LocalProvider`, and through `RemoteProvider` using the real helper over a pipe.
  - Undo is disabled once the disk no longer matches, and never offered for a vanished file.
- **`claude-preflight`**
  - Finds Claude Code in the known locations, using `Paths.homeOverride` and fake binaries that print a version.
  - Version comparison.
  - Falling back to the login shell, including the timeout.

All existing suites must still pass unchanged, especially `bytes` and the regression suite.

**Manual checks on a release build.** Mark on a second macOS user account where noted.
1. A project on the Desktop, on a fresh account: Terminal's own folder prompt, then the trust prompt, then the first change.
2. A personal skill, with and without a selection, with and without a request.
3. A file opened from Finder, outside every project.
4. A file on the mini using a password login: no second prompt. Then disconnect Crook and confirm the session continues.
5. The mini without Claude Code installed: alert A‑2.
6. Claude Code missing on this Mac, on a fresh account: alert A‑1.
7. VoiceOver on: announcements, and `--ax-screen-reader` is passed.
8. A 1440×900 screen, Crook in full screen, and two displays.
9. Two sessions at once, each on its own file.
10. Quit Crook during a session, relaunch, and confirm watch mode comes back.
11. Close the Terminal window during a session. Separately, click End Session.
12. Drop the network during a session on the mini.
13. Undo, Redo, and Undo disabled after a later edit.
14. A conflict when starting (A‑5), and a remote file with unsaved edits when starting.

---

## 14. Checks, and what they found

These ran on 11 September 2026: macOS 26.6.2, Claude Code 2.1.268, a built-in display plus a 3440×1440 display. Remote checks ran against a user-level `sshd` on 127.0.0.1 with a throwaway key, because `mac-mini` wasn't reachable that day.

| # | What was checked | Result | What the design does |
|---|---|---|---|
| S1 | Opening a `.command` with Terminal through `NSWorkspace.open(_:withApplicationAt:configuration:)` | **Pass.** The runner starts about 1.3 s after the open, with no dialog. | As designed. |
| S2 | Placing Terminal's window | **xterm sequences fail.** Pixel resize (`CSI 4 t`) is ignored, move (`CSI 3 t`) is relative to whichever screen the window is on, and character resize (`CSI 8 t`) doesn't help. **AppleScript `bounds` fails across displays:** the same target landed exactly from the built-in display but was shifted, or clamped onto the other display, from the ultrawide. **AppleScript `frame` passes.** Given AppKit global coordinates, it landed exactly from either display, with no prompt. | The runner sets `frame` twice, a second apart. Crook reads the frame back through CGWindowList and only moves itself once Terminal is where it asked. |
| S3 | The runner closing its own window | **Pass, by window ID rather than tty.** A finished window keeps reporting its old tty, and the pty is then reused, so tty isn't a unique key. | Find the window by busy tty at start, close it by ID at the end, in a detached `setsid` `osascript` that waits for the tab to go idle. |
| S4 | Interactive flags | **Pass.** The appended system prompt is applied. The first message after `--` is sent automatically, after the trust question is answered Yes. `--name` sets the Terminal title. `--permission-mode default` (and `manual`) override a project's `acceptEdits`. `Edit(//path)` approves exactly that file, symlinked paths included. The trust question defaults to **No, exit**, and choosing it exits with 1 in 0.3 s. | Minimum version 2.1.268. First-time copy names the choice. A‑10 covers a declined trust question. |
| S5 | Ending Claude Code | **Pass.** SIGTERM exits with 143 in 0.7 s, `/exit` exits with 0, Ctrl‑C twice exits with 0. A session at the trust question ignored SIGTERM. Transcripts weren't written when the session ran nested inside another Claude Code session, so resuming isn't promised anywhere in the UI. | SIGTERM, then SIGKILL after 3 s. |
| S6 | Terminal's ssh joining Crook's connection | **Pass.** With no usable key, `ssh -t` joined the master ("Shared connection … closed") and kept running after Crook's long-lived client was killed. | As designed. |
| S7 | Finding `claude` over ssh | **Pass.** A non-login shell over ssh doesn't have it on PATH. `$SHELL -lic 'command -v claude'` finds `~/.local/bin/claude`. | As designed, with the known-locations fallback. |
| S8 | A macOS folder permission denial | **Not run.** Simulating a TCC denial would mean resetting Terminal's real privacy grants. | Exit 92 covers any failure to list the folder. Tested with a folder that has no read permission. |

---

### 14.1 End to end, in the real app

A build compiled with `-D CROOK_E2E` drives a real session on its own (`scripts/e2e-claude.py`): the popover, the checks, Terminal, a real Claude Code, the reload, an ending, then review, Undo, Redo and Done. It photographs only Crook's and Terminal's windows. Every run was on 11 September 2026, against a scratch file:

| Scenario | Result |
|---|---|
| End Session | The popover, then checks, then opening, then running in 1.6 s. Claude received the first message with its line range, edited without a prompt, and ended with the one-line `/exit` reminder from Crook's appended prompt. Crook highlighted exactly lines 5, 7, 8 and 9 and showed +4 −4. Typing and `insertText` while read-only never reached the buffer, and the nudge showed. End Session finished in 0.7 s and Terminal's window closed. Undo restored the baseline bytes exactly; Redo restored Claude's. Done removed the session folder. |
| Crook makes room, then `/exit` | The first run found the `bounds` problem (S2): Terminal landed 187 pt off, so Crook correctly didn't move. After the switch to `frame`, Terminal landed exactly on its plan, and Crook narrowed from 3300 to 2880 pt. `/exit` ended the session as finished, Terminal closed, and Crook's frame was restored. |
| Quit Crook mid-session, relaunch | The runner kept going in Terminal. The relaunched Crook found the session running and read-only, ended it, and reviewed it. Its frame was restored once the size-only comparison for reattached sessions was added. |
| Another Mac (localhost sshd, throwaway key, real ssh and Claude Code) | Terminal's ssh joined the shared connection. The remote runner found `claude` through the login shell and ran it in the project folder. Claude made exactly the requested change. End Session stopped ssh (exit 255, counted as finished) and Terminal closed. |

Not run for real, and covered by unit tests plus the copy: the failure alerts (not installed, too old, folder access, closed without changes), because each needs a broken machine to trigger honestly; and a session on `mac-mini` through the Crook UI, which wasn't reachable that day.

---

## 15. Decisions made in this spec

These seven calls go beyond the answers in §3. All seven were approved with the spec on 11 September 2026. Each is reversible, but all of them change what people see:

1. **Ask in a popover before Terminal opens,** with an optional request. ⌥-click skips it.
2. **The file is read-only in Crook while Claude has it.** End Session is how to take it back.
3. **Crook moves its own window to make room for Terminal,** and puts it back afterwards.
4. **On `/exit`, Terminal closes and Crook comes forward.**
5. **Undo Changes and Redo Changes on the end banner.** This is the first time Crook writes a file for the person as a single action. It writes only bytes they already had.
6. **A title bar button that's always visible** while a file is open. Crook's design notes keep a budget of two always-visible controls, and this adds a third.
7. **The label "Edit with Claude" and the `sparkles` symbol.**

## 16. Not in this version

- Continuing a previous session on the same file. Session IDs are recorded from the start, so this is a small addition later.
- Choosing iTerm2, Ghostty or Warp instead of Terminal.
- A terminal panel inside Crook.
- A mode that works without Terminal, for people who don't have the Claude Code CLI.
- Showing "Claude is thinking" inside Crook. That would need hooks, and hooks on another Mac can't reach this one.
- Special handling for files that contain secrets.
