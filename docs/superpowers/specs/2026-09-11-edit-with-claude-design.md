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

The button is as wide as what it currently says, so the window title keeps the rest of the title bar.

**The menu.** File ▸ **Edit with Claude…** ⇧⌘E, directly below Reload from Disk. While this file has a session running, the item reads **Show Claude Session** with the same shortcut, and **End Claude Session** appears below it.

**Skipping the popover.** ⌥-clicking the button, or pressing ⌥⇧⌘E, opens the session straight away with no request.

**The sidebar.** While a file has a session running, a small yellow `sparkles` symbol appears where its change count normally sits. After the session ends it turns grey, until Done. That keeps the session easy to find after navigating to other files.

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
  - **Return** opens the session. **⇧Return** starts a new line. **Esc** closes the popover. Return while an input method is composing finishes the composition instead.
  - Closing keeps the draft for that file until Crook quits. So does opening a session that fails its checks or closes at the trust question: **Try Again** comes back to the popover with the request still there. The draft is cleared once a session has run.
- **The footer.**
  - This Mac: "Opens Claude Code in Terminal, beside this window. Each change appears here as Claude saves it."
  - Another Mac: "Opens Claude Code on mac-mini, in Terminal beside this window. Each change appears here as Claude saves it."
- **A file inside a `.claude` folder** gets one more line: "Claude Code asks in Terminal before it changes a file in a .claude folder. Choose Yes there, and your changes appear here." (§10.2, check S10).
- **First-time line.** Until a session has started once, one more line appears, in secondary ink so it can be read: "The first time, Claude Code may ask you to log in. In a folder it hasn't seen before, it asks whether you trust it: choose “Yes, I trust this folder”." That trust question defaults to **No, exit** (check S4), which is why the line names the choice to make.
- **The button.** **Open Claude Code**, the default button.

**Why a popover, instead of opening Terminal straight away:**
- It puts the first instruction, often the only one, in the app the person is already looking at, next to the selection it applies to.
- With a request typed, Claude starts working as soon as Terminal opens instead of greeting first.
- It's the one place the feature can explain itself without a one-time sheet.

An empty request still works, and ⌥-click skips the popover entirely.

### 5.3 Checks before Terminal opens

When the person presses Open, the popover closes, the button shows **Opening…** and the editor becomes read-only. Crook runs these checks in order and stops at the first failure:

1. **The file still exists.** If it disappeared since the popover opened: alert A‑7.
2. **There's no conflict.** If the file changed on disk while the person had unsaved edits, Crook asks which version Claude should work on (alert A‑5). That covers a change the window watched happen (`.conflict`) and one it couldn't: a document held with unsaved edits while another file was open, or a file on another Mac. A local document compares the file's modification date with the one it last read or wrote; a remote one compares the bytes.
   - **Use My Version** saves over the disk copy.
   - **Use Disk Version** takes the disk copy, the same as ⌘R. If the disk copy can't be read, the edits stay and Crook shows alert A‑13 instead of going on to save them over it.
   - **Cancel** stops here.
3. **Unsaved edits are saved.** Keystrokes still on their way from the editor are taken first, so the last few characters typed aren't left out. A local file saves in place. A remote file goes through `saveRemote()`. If saving fails, Crook shows its existing save error and nothing opens.
4. **Crook is connected** (another Mac only). If not: alert A‑4, with a Reconnect button.
5. **Claude Code is installed, and new enough, on the Mac that holds the file.**
   - **This Mac:** any copy that is new enough will do, because the session runs the copy found here, and Macs collect more than one (a native install beside an old Homebrew one, or an npm install under nvm). Crook tries the installers' locations, then every `claude` along the PATH the person's login shell sets up. It reads that PATH from a marked line rather than asking `command -v claude`, which answers with the alias when someone has aliased claude, and gives the shell 6 s, because one that loads nvm and conda can take seconds. Each copy's `claude --version` runs with its own folder and that PATH ahead of the system's, giving up after 4 s, so a copy that runs through an interpreter beside it still answers. The first copy new enough wins; if none is, A‑3 names the newest version found. A good answer is cached until Crook quits, and checked again if the cached path disappears.
   - **Another Mac:** one command over Crook's existing connection.
   - **Missing:** alert A‑1 or A‑2. **Too old:** alert A‑3, with an Update in Terminal button.

Checks take under 300 ms once Claude Code's location is cached. The first check on this Mac takes about a second where the installer put Claude Code, and at most about 10 s if the login shell and a version check both hang. On any failure the editor becomes editable again and the button returns to idle.

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

**The running banner:** the title with its note on a second line beneath it, so the note keeps the width Crook narrows itself to.

> ● **Editing with Claude in Terminal**
> Read-only here until you finish  [Show Terminal] [End Session]

For a file inside a `.claude` folder, the note reads **Claude Code asks in Terminal before changing it** until the first change lands.

After Claude's first change, the note becomes **+12 −4 so far · read-only until you finish**.

**When a change lands:**

- **Reload.** Crook reloads through its existing path in `handleExternalChange`: the buffer is clean, so the file reloads, the caret and scroll position stay put, and the icon turns yellow.
- **Precise highlights.** Highlights mark only the lines that actually changed, computed with `UnifiedDiff` against the previous content. A rename that touches line 3 and line 80 highlights those two lines, not the 78 lines between them. Past about 630 lines, where the full comparison would be too slow, an edit-distance comparison takes over, so a long file stays just as precise; only a rewrite of more than 1,000 lines is shown as one block. This applies only during a session. Outside sessions, highlighting still uses `LineDiff`.
- **Scrolling.** If none of the changed lines are visible, the editor scrolls so the first one sits a third of the way down. If one of them is already visible, or the person scrolled within the last 3 s (with the wheel or trackpad, the scroll bar, or the arrow, Page, Home, End and Space keys), Crook leaves their position alone. The tally in the banner still updates.
- **The tally.** Lines added and removed, counted against the baseline.
- **VoiceOver** announces "Claude changed lines 12 to 18" when the changed lines are next to each other, and "Claude changed 2 lines" when they aren't, so a rename on lines 3 and 80 doesn't sound like everything between them.
- **Claude's version is kept.** Crook stores the bytes of each change as it lands. If the session ends where Crook can't read the file (the connection dropped, or Crook was closed), Undo and Redo still have Claude's last version to work with.
- **⌘D** (Show Changes) shows the diff against the baseline, meaning everything Claude has changed this session.

**If the person tries to type** (a character, Delete, a paste, or dictation), nothing changes in the file. The banner briefly brightens and its note reads **To edit it yourself, finish in Terminal or click End Session** for 4 seconds, and VoiceOver says so. Selecting, copying, scrolling and zooming all keep working. Save is unavailable: the buffer is what was last read from disk, and writing it could only put back an older version.

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

Undo becomes available after reconnecting. It works from the last version of the file Crook saw land, and, like every Undo, only while the disk still holds exactly that version.

**End banner, Claude Code stopped with an error:**

> **Claude Code stopped unexpectedly** · +3 −1 saved before it stopped  [Review Changes] [Undo Changes] [Done]

**Review Changes** (⌘D) opens Crook's existing change view, comparing the baseline with the file now. Its header reads **Changes Claude made to SKILL.md — 14 added, 6 removed**.

**Undo Changes** writes the baseline bytes back exactly. The banner becomes:

> **Restored the version from before Claude's changes**  [Redo Changes] [Done]

**Redo Changes** writes the session's final bytes back.

Undo and Redo are each offered only while the file still matches what they would replace. The button compares what's on screen, as text, with that version; the write itself compares the disk's exact bytes, and if they no longer match it changes nothing and says so (alert A‑14). Otherwise the button is disabled, with the tooltip "This file has changed since the session ended." Undo is never offered for a file that was moved or deleted, because writing the old path back would create a duplicate. It's also not offered when Crook never saw Claude's version: a session that ended while Crook was closed, with no change landing while Crook was watching. Crook can't tell Claude's last write from something that changed the file afterwards, so that banner offers Review Changes and Done.

**How long the end banner stays.** Until the person clicks **Done**, types in the file, or starts another session on it. It stays across moving to other files and back, and across quitting and reopening Crook.

### 5.7 Crook quits or restarts during a session

The session keeps running, because it belongs to Terminal, not to Crook.

When Crook next launches, it looks for sessions that are still running. It confirms each process is the one Crook started, not a reused process ID, and puts those files back in watch mode. A session that ended while Crook was closed shows its end banner when its file is next opened.

If Crook's window is closed when a session ends, Crook still comes forward, but the window doesn't jump to the file. The sidebar's `sparkles` symbol marks it, and the end banner appears when it's opened.

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
| running | ● Editing with Claude (yellow `sparkles` when the window is too narrow for the label) | Editing with Claude in Terminal · Read-only here until you finish, or +N −M so far |
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
- **Keyboard.** Every action works from the keyboard: ⇧⌘E, ⌥⇧⌘E, Return, Esc and ⌘D. The banner buttons join the key-view loop when the banner appears, and focus returns to the text after one of them removes itself. Esc answers OK in two-button alerts.

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
| A‑9 | The session didn't report starting within 15 s | Claude Code didn't start. | If a Terminal window opened, it shows what went wrong. | Try Again · OK |
| A‑10 | Claude Code exited with an error without changing the file. Declining the trust question does exactly this: it exits with 1 in under a second (check S4). | Claude Code closed without making changes. | If it asked whether to trust this folder, try again and choose “Yes, I trust this folder”. Otherwise, Terminal shows what went wrong. | Try Again · OK |
| A‑11 | The project folder is missing | The folder for this file is missing on mac-mini. (For this Mac: The folder for this file is missing.) | Claude Code needs to start in that folder. It may have been moved or renamed. | OK |
| A‑12 | Terminal's ssh failed within 10 s | Couldn't reach mac-mini from Terminal. | ssh reported a problem, and Terminal shows what it said. Check that Crook is still connected, then try again. | OK |
| A‑13 | Use Disk Version (A‑5) couldn't read the disk copy | Couldn't read SKILL.md from disk. | Your edits are still here. Try again, or choose Use My Version. | OK |
| A‑14 | Undo or Redo found the file no longer holding the version it replaces | SKILL.md has changed since the session ended. | Undo (or Redo) would overwrite those changes, so Crook left the file as it is. | OK |

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
| Crook's window is closed during a session | The session continues, and the button and banner go with the window. Opening the file again brings them back: watch mode while the session runs, the end banner after. |
| The screen is too narrow for both windows (under 1280 pt) | Crook narrows to 720 pt and Terminal overlaps its right edge. |
| The change view is open when a session starts | It closes first. |
| The file path contains `* ? [ ] { }` | No pre-approval rule is passed, so Claude Code asks before editing this file too. Everything else works the same. |
| A session for a personal file | Runs in `~/.claude`. Claude Code then records that folder as a project, so Crook's project suggestions leave `~/.claude` out. |
| The person uses Claude Code's own `/rewind` (Esc Esc) | Works as normal. Crook's Undo covers the whole session for this file. |
| Claude Code is offline, rate-limited or logged out mid-session | Claude Code's own messages appear in Terminal. Crook stays in watch mode until the session exits. |
| Another app is the default for `.command` files | Crook always opens Terminal explicitly, so that setting doesn't matter. |
| The Mac restarts and a session's process ID is reused | Crook records each process's start time. If it doesn't match, the session counts as ended. |
| Files that may contain secrets (`.mcp.json`, `settings.local.json`) | No special handling. Claude Code reads them the way it reads any file. |
| Several copies of Claude Code installed | The first new enough is used (§5.3), and that copy is the one Terminal runs. |
| The person presses Ctrl‑Z in Claude Code | Claude Code and the runner are suspended together, and Claude Code says to type `fg`, which brings both back. End Session still ends it (§11.6). |
| Terminal is set to close windows when the shell exits | A clean ending closes the window anyway. After an error the runner exits unclean, so "Close if the shell exited cleanly" keeps the window to read. |
| A login script asks a question when Terminal opens (an oh‑my‑zsh update prompt) | It can take the command Terminal types, and the runner never starts: A‑9, whose Try Again opens a new window. |
| Claude deletes the file and writes it again | The watcher reports the new file as a change once it's back, and the "moved or deleted" banner goes away. |
| The window is closed while its file has no unsaved edits | The document closes with it, so opening the file again reads it fresh from disk. |
| CLAUDE.md is a link to AGENTS.md | Saving, autosaving, the save before a session, and Undo and Redo all write AGENTS.md and leave the link a link, on this Mac and on another. A change to AGENTS.md made while a linked document sat unsaved in the background isn't raised as a conflict before a session (NSDocument keeps the link's own date); while the file is open the watcher follows the link and reloads it as usual. |
| A project on another Mac reached through a linked folder (Dropbox, Google Drive) | Writes are checked against the project as the sidebar shows it, not where the link leads, so they save. |

---

## 10. What Claude is told

### 10.1 Working folder

| File | Folder Claude Code starts in |
|---|---|
| Inside a project in the sidebar | That project's root. The longest matching root wins when projects are nested. |
| Inside that machine's `~/.claude` | `~/.claude` |
| Anywhere else | The file's own folder |

The home folder is the starting folder only for a file directly inside it, such as `~/notes.md`, where the file's own folder is home. Claude Code can't remember trust for the home folder, so those sessions ask every time. A file in any folder below home starts in that folder.

### 10.2 The command

```
claude
  --session-id <uuid>
  --name "Crook: SKILL.md — release-notes"
  --permission-mode default
  --settings '{"permissions":{"allow":["Edit(//Users/alice/atlas/.claude/skills/release-notes/SKILL.md)"]}}'
  --append-system-prompt "<§10.4>"
  [--ax-screen-reader]
  -- "<first message>"
```

- **`--permission-mode default`.** This is the ask-first mode. Version 2.1.268 lists it as `manual`, but it still accepts `default`, the name older versions also know, and the two behave identically (check S4). Crook passes it explicitly so that someone whose own default is `acceptEdits`, `auto` or `bypassPermissions` still gets asked before Claude edits any other file in this session. Check S4 confirmed that a command-line flag overrides a project's `acceptEdits` for that session.
- **The pre-approval rule.** One `Edit(//absolute path)` rule. The `//` anchors the path at the root of the filesystem. Edit rules cover every tool that edits files. The rule is left out when the path contains glob characters.
  - **Passed as settings, not `--allowedTools`** (check S9). That flag splits its value at a space or comma after a closing parenthesis. A folder named "Notes (copy) v2" cut the rule in two and left the file unapproved; "Scripts (old) Bash tools" would have produced a bare `Bash` rule, allowing every shell command.
  - **In both Unicode forms** when they differ (check S9). Claude Code writes the path in composed form, so a folder whose name is stored decomposed never matched a rule in that form alone.
- **Files inside a `.claude` folder always ask** (check S10). Claude Code treats them as sensitive: no allow rule or permission mode short of skipping every check lets Claude edit one without asking. Skills, commands and agents all live there, so Crook says so rather than promising otherwise:
  - the popover adds "Claude Code asks in Terminal before it changes a file in a .claude folder. Choose Yes there, and your changes appear here.";
  - the running banner's note reads "Claude Code asks in Terminal before changing it" until the first change lands;
  - the system prompt tells Claude the question is expected (§10.4).
- **Argument order.** The first message comes after `--`, so a message starting with `-` is still a message. The tests pin this order.
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
- {one of:}
  Edits to this file are already approved. Change what they ask for and nothing
  else.
  {inside a .claude folder:} Claude Code asks them to approve edits to this file,
  because it is inside a .claude folder. That is expected, not an error. Change
  what they ask for and nothing else.
  {no rule, because the path has glob characters:} Claude Code asks them to
  approve edits to this file. Change what they ask for and nothing else.
- Keep everything you weren't asked to change exactly as it is: line endings,
  indentation, trailing whitespace, blank lines, the final newline, and
  frontmatter fields.
- If their request also needs other files changed (a skill folder renamed, a
  reference in another CLAUDE.md, a command that points at this file), tell them
  which files and why, and wait for them to say yes before editing any of them.
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
   - If Crook has already given up waiting (an `abandoned` file), it exits before and again just after writing `runner.pid`, removing it. Crook, on giving up, looks for `runner.pid` once more and watches a runner that reported in the same moment. One that stands down without a report counts as not started.
2. **Places its window.** It asks Terminal, through `osascript` and `window.applescript`, for the ID of the window whose busy tab is on its own tty, and writes that ID to `window`. If Crook asked for a position, it sets that window's `frame` twice, a second apart (check S2). A window with more than one tab is left alone. The AppleScript window ID is the same number `CGWindowListCopyWindowInfo` reports, which is how Crook confirms the move landed.
3. **Gets ready to run Claude Code.**
   - **This Mac:** it changes into the working folder and lists it, which is where a macOS folder permission denial shows up (exit reason `folder-access`). It then finds `claude` on the person's own PATH, which comes from the login shell Terminal started. If that fails, it uses the path Crook found during the checks.
   - **Another Mac:** it runs `/usr/bin/ssh -t <Crook's connection options> <host> <remote command>`.
4. **Starts Claude Code, or ssh, in the foreground** through `/bin/zsh -c 'print $$ > …/child.pid; exec "$@"' crook <argv>`. That records the process Crook will signal for End Session, and passes the arguments as arguments, never as code.
5. **Reports the exit.** After that process exits, it changes back into its session folder and writes `exit` as "status seconds". If the folder is gone (a cache cleaner, or a session Crook forgot), it exits without a report rather than writing one into the project.
   - After End Session, it closes its own window.
   - After a clean exit (0 or 130), or its own failure (90–92), it brings Crook forward with `open -b` and closes its window. With more than one copy of Crook installed, `open -b` brings forward the copy that is running, even an older one, and only launches the newest when none is (check S12). The close is a detached `osascript … close-when-idle`, started through `perl -MPOSIX -e 'setsid()…'` so it isn't counted as a process running in the window. It waits up to 10 s for the tab to go idle, then closes the window by ID with no prompt (check S3), but only if it still has one tab, nothing running, and the tty the runner was given.
   - Otherwise it leaves the window open, with a final line, and exits with Claude Code's status. A Terminal set to close windows when the shell exits cleanly then keeps it open to be read.

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
3. asks that Mac's login shell (`$SHELL -lic`) where `claude` is and for its environment;
   - the probe is plain enough for zsh, bash and fish: `command -v claude` marked with `CROOK_EXE=`, then `env -0` between markers;
   - the shell runs in a session of its own (`setsid`), reading nothing, with its output in a temporary file, and is killed with its process group after 8 s. It can't take keystrokes meant for Claude, can't hang the session, and a greeting or path printed by a login script is never taken for the answer;
4. if that gives no path (an alias or function named claude answers with itself), looks along that shell's PATH, then `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude` and `~/.claude/local/claude`, or exits with 90;
5. exports that shell's environment, less what describes the shell and terminal (`PWD`, `SHLVL`, `TERM*`, `SSH_*`, `TMUX*`, zsh's own specials, the runner's own variables, and any name zsh holds read-only or as an array, which it can't export and which would end the script), and runs Claude Code with the arguments as arguments. API keys, proxies and a `CLAUDE_CONFIG_DIR` set in the far Mac's shell files then apply, as they do in its own Terminal.

The far-Mac check (§5.3) uses the same probe and environment for `claude --version`.

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

- **Reattaching.** On launch, Crook reattaches every session folder whose `runner.pid` names a live process running its `launch.command`.
  - A folder whose runner is still alive is never deleted, whether or not it has a record: an Update in Terminal, or a session whose record this version can't read.
  - Records are read tolerantly. Only the file, machine and folder are required; a missing field takes its default, and an outcome this version doesn't know counts as finished. An unreadable record is kept until its folder has been idle for 7 days.
  - A session found dead at launch is dated by the newest of its files (`exit`, `final`, `window`, the pid files, the record), not by the relaunch, so the 7-day clean-up counts from when it really ended.

### 11.6 End Session

Crook sends SIGTERM to the process in `child.pid`. That's Claude Code on this Mac, or ssh for another Mac, where ssh exiting hangs up Claude Code on the far side. If the process is still alive after 3 s, Crook sends SIGKILL. The fallback is required: during the spike, Claude Code sitting at its trust question ignored SIGTERM (check S5).

Ctrl‑Z in Claude Code suspends it and the runner together; typing `fg` in that window brings both back (check S11). A suspended process holds SIGTERM until it continues, and a suspended runner can't collect its child or report, so End Session also sends SIGCONT to both, after SIGTERM and again after SIGKILL.

Crook only signals a process that is still this session's. The process in `child.pid` must still be the runner's child, according to the kernel. If it isn't, because it exited and its process ID was reused, or the runner hasn't started it yet, Crook signals the runner, and only after confirming the runner is still running this session's `launch.command`. Both checks run again before SIGKILL.

When a session ends in an alert rather than a banner, Crook forgets it at once but keeps its folder for 10 s more. The runner is still closing its Terminal window at that moment, and the script that does it lives in that folder.

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
| `SessionBanner` | The banner view and its states. When only its text changes, it keeps the same buttons, so a click in progress and VoiceOver's place survive each change that lands. | Nothing |

Changes to existing code:

- **`editor.js` and `EditorBridge`:**
  - `setReadOnly(Bool)`, using a CodeMirror compartment around `EditorState.readOnly`;
  - `scrollToLines(lines)`, which scrolls only when none of the lines is visible and the reader isn't scrolling;
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
  - The rule travels in `--settings`, in one piece for folders like "My Notes (copy) it's", and in both Unicode forms; `--allowedTools` is never used.
  - Files inside a `.claude` folder are recognised, and the system prompt says approval is asked, never "already approved", for them and for paths with no rule.
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
  - A session folder that disappears mid-session writes nothing into the project; a runner Crook stopped waiting for starts nothing; after an error the runner itself exits unclean.
  - The far Mac: the claude found is its login shell's even when login scripts print paths; claude gets that shell's environment; a login shell that hangs is given up on and the installer's location is used.
- **`claude-registry`**
  - Detects a session starting, and detects it exiting using a real child process.
  - Rejects a reused process ID when the start time doesn't match.
  - Reattaches from a session folder.
  - End Session signals the child process, and never a process that isn't the runner's child.
  - A session folder kept for a delay is still there before it and gone after.
  - Cleanup after Done and after 7 days.
  - End Session ends a session that Ctrl‑Z suspended.
  - A record from another version is still read; a folder a live runner uses is left alone; a session found dead is dated by its files; a runner that stood down counts as not started; a delayed discard removes the record at once.
- **`claude-review`**
  - Tally counts.
  - Undo and Redo write exact bytes for CRLF files, files without a final newline, and files with a byte-order mark. Tested through `LocalProvider`, and through `RemoteProvider` using the real helper over a pipe.
  - Undo is disabled once the disk no longer matches, and never offered for a vanished file, or when Crook never saw Claude's version.
  - Undo and Redo through a symlink change the file it points to and keep the link, its permissions and extended attributes.
  - VoiceOver's wording for neighbouring and scattered lines.
- **`claude-preflight`**
  - Finds Claude Code in the known locations, using `Paths.homeOverride` and fake binaries that print a version.
  - Version comparison.
  - Falling back to the login shell, including the timeout.
  - An alias doesn't hide the program on the shell's PATH; an old copy doesn't hide a newer one; the newest of several old copies is named; a copy that needs a program beside it still reports its version; a version printed after a warning is found.
  - Not installed, with this Mac's own Homebrew locations set aside so the test means the same on every Mac.

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

### 14.0 Checks after the pre-release review

These ran on 11 September 2026, against Claude Code 2.1.268 and 2.1.269, with the same Mac.

| # | What was checked | Result | What the design does |
|---|---|---|---|
| S9 | The pre-approval rule on unusual paths, with `claude -p` and a one-word Edit | **`--allowedTools` fails** for a folder with a space or comma after `)` ("My Notes (copy) its", "NOTES (1) final.md"): the flag splits there, and escaping the parentheses doesn't help. Spaces, parentheses without a following space, apostrophes and composed accents pass. **A decomposed accent fails**, because Claude writes the path composed. **`--settings` JSON passes** for every case, with both forms of an accented path. | §10.2: rules as settings, in both forms. |
| S10 | Files inside a `.claude` folder | **Always asks.** An allow rule in settings or `--allowedTools`, a directory glob, a `~` rule and `acceptEdits` all left the edit denied in `-p`; Claude Code's message calls it a sensitive file. Interactively it asks "Do you want to make this edit to SKILL.md?" with Yes selected. A project `CLAUDE.md` outside `.claude` edits without asking. | §10.2: the copy says Claude Code asks. The README says to choose Yes, and not the second choice, which can switch the whole session to accepting edits. |
| S11 | Ctrl‑Z in Claude Code, in a job-control shell as Terminal runs it | Claude Code and the runner were both suspended; `fg` resumed both and Claude Code redrew. SIGKILL left Claude Code a zombie under the suspended runner, so End Session never completed. With SIGCONT added, End Session finished in 3 s in real Terminal. | §11.6. |
| S12 | `open -b` with two registered copies of an app | With either copy running, `open -b` activated that copy and launched nothing. With neither running, it launched the newer. | §11.3: unchanged. |
| S13 | How installs start | The current npm package's `claude` is a native binary, like the installer's and Homebrew's; a Dock-launched app's PATH lacks nothing it needs. This Mac had both 2.1.268 (installer) and an old Homebrew 2.1.185. `claude update` recognises a Homebrew install and upgrades through Homebrew. | §5.3: every copy is considered; Update in Terminal is unchanged. |

### 14.1 End to end, in the real app

A build compiled with `-D CROOK_E2E` drives a real session on its own (`scripts/e2e-claude.py`): the popover, the checks, Terminal, a real Claude Code, the reload, an ending, then review, Undo, Redo and Done. It photographs only Crook's and Terminal's windows. Every run was on 11 September 2026, against a scratch file:

| Scenario | Result |
|---|---|
| End Session | The popover, then checks, then opening, then running in 1.6 s. Claude received the first message with its line range, edited without a prompt, and ended with the one-line `/exit` reminder from Crook's appended prompt. Crook highlighted exactly lines 5, 7, 8 and 9 and showed +4 −4. Typing and `insertText` while read-only never reached the buffer, and the nudge showed. End Session finished in 0.7 s and Terminal's window closed. Undo restored the baseline bytes exactly; Redo restored Claude's. Done removed the session folder. |
| Crook makes room, then `/exit` | The first run found the `bounds` problem (S2): Terminal landed 187 pt off, so Crook correctly didn't move. After the switch to `frame`, Terminal landed exactly on its plan, and Crook narrowed from 3300 to 2880 pt. `/exit` ended the session as finished, Terminal closed, and Crook's frame was restored. |
| Quit Crook mid-session, relaunch | The runner kept going in Terminal. The relaunched Crook found the session running and read-only, ended it, and reviewed it. Its frame was restored once the size-only comparison for reattached sessions was added. |
| Another Mac (localhost sshd, throwaway key, real ssh and Claude Code) | Terminal's ssh joined the shared connection. The remote runner found `claude` through the login shell and ran it in the project folder. Claude made exactly the requested change. End Session stopped ssh (exit 255, counted as finished) and Terminal closed. |
| After the pre-release review: a full session on a 131-line file | Change on line 128 highlighted and scrolled into view, banner buttons kept, End Session in 1 s with Terminal closed through the new tty check, window closed and the file reopened fresh, Undo and Redo byte-exact, Done. |
| Ctrl‑Z, then End Session | Runner and Claude Code both suspended (`T`); End Session finished in 3 s and the window closed. Typing afterwards autosaved to disk within 20 s with no "changed by another application" sheet. |
| A skill inside a `.claude` folder | Popover and banner showed the `.claude` note; Claude Code asked in Terminal; End Session with no change ended as finished with "This file wasn't changed". |
| Another Mac, a project in "remote proj (copy) v2" | The far-Mac check found 2.1.269 in 0.9 s through the new probe. Terminal's ssh joined the connection, Claude edited without asking through the settings rule, End Session ended it (ssh 255, finished) and the window closed. |
| After the second review: a change far down the file, then closing and reopening the window | The change landed on line 128 of 131 while the window showed the first 30 lines. The editor scrolled to it (scrollTop 0 to 3189, the highlighted line visible), and the banner kept its buttons as its tally updated. The title bar button measured 140 pt idle, 111 pt opening and 153 pt running. With the session ended, closing the window removed the button and banner. Opening the file again brought the end banner back, and Undo and Redo were still byte-exact. |

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
