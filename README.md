# Crook

**A quiet editor for the files that steer Claude Code.**

Skills, `CLAUDE.md`, slash commands, subagents, memory notes — the files that
decide how Claude behaves in your projects. Crook shows you all of them in one
place, tells you which ones Claude actually reads, and shows you what changed
when Claude rewrites them behind your back.

A crook is the hooked staff a shepherd uses to steer the flock. These files are
how you steer yours.

---

## Install

1. Download `Crook-x.y.z.zip` from
   [Releases](../../releases/latest).
2. Unzip it and drag **Crook** to your Applications folder.
3. **First launch only:** double-click it. macOS will refuse, because Crook is
   not notarised — that costs an Apple developer account and this is a small
   free tool. Open **System Settings ▸ Privacy & Security**, scroll to the
   bottom, and click **Open Anyway** next to the message about Crook. Confirm.

   You do this once. After that it opens like anything else.

Requires **macOS 26** or later, Apple Silicon.

If you would rather not take a stranger's binary — reasonable — [build it
yourself](#building). It takes about a minute.

---

## What it does

**Shows you every file Claude reads, in one tree.** Your personal
`~/.claude` at the top, then each project you add. Only files Claude Code
actually reads — not a file browser. Vendored `node_modules` skills and session
transcripts never appear.

**Tells you why Claude reads the open file.** A line in the bottom-right says
what makes this file load: `Personal skill · /release-notes`, `Project memory · read
for any file in this folder or below`, or `Not in a directory Claude Code scans
for skills` — which is the one that saves you an afternoon. It updates as you
type: add `disable-model-invocation: true` to a skill and the sentence changes
on the keystroke that completes it.

**Marks what Claude changed while you were away.** Claude Code rewrites these
files constantly. Files it touched since you last opened them carry a signed
line count in the sidebar — `+7`, `−12`. Open one and Crook shows you a diff of
what moved before you carry on. It is a viewer, not a merge tool: the file on
disk is the file.

**Finds paths that no longer exist.** A slash command pointing at a folder you
renamed is silently dead — it looks completely fine and does nothing. Crook
underlines it and says where the path stops being real.

**Never changes a byte you did not.** Line endings, trailing whitespace, a
missing final newline, indent style — all preserved exactly. These files are
read by a machine, so a diff you did not author is not cosmetic noise. macOS
smart quotes and dash substitution are disabled inside Crook for the same
reason.

**Works on another Mac over SSH.** If Claude Code runs on a headless Mac mini
you reach over Tailscale, Crook can edit that machine's files as if they were
local — the same tree, the same reach line, the same change marks. Click
**Connect to a Machine…** and type the name you would use with `ssh`. Crook
uses your existing SSH configuration, so an alias from `~/.ssh/config` is
enough, and it installs a small helper on the far machine by itself.

This is not a mounted disk, and that is deliberate. Mounting gets two things
wrong that cannot be fixed: paths inside your files get checked against the
*wrong* machine, so live links read as broken, and no mounted filesystem can
report a change another host made — which is the whole point of the change
marks. A helper on the far side answers both correctly.

**Writes nothing into your projects.** No dotfiles, no sidecars, no index. What
Crook remembers lives in its own container.

---

## Using it

| | |
|---|---|
| `⌘O` | Open a file |
| `⌘S` | Save |
| `⌘R` | Reload from disk, discarding your edits |
| `⌘D` | Show what changed since you last opened this file |
| `⌘+` `⌘−` `⌘0` | Bigger, smaller, actual size |

The machine you are looking at is named in the bottom-left of the sidebar, and
in the window subtitle when it is not this Mac. One window is one machine.

Click **Add a Project…** in the sidebar and pick any folder with a `.claude`
directory or a `CLAUDE.md`. Nothing is scanned or added without you choosing it.

The sun/moon in the bottom-left cycles light, dark, and follow-the-system.

---

## Building

You need Xcode 26 (for the macOS 26 SDK) and Node 20 or later.

```sh
git clone <this repo>
cd crook
cd web && npm ci && cd ..
./scripts/build.sh          # → build/Crook.app
open build/Crook.app
```

Tests:

```sh
./scripts/test.sh           # everything
./scripts/test.sh bytes     # one suite
```

To cut a release artifact:

```sh
./scripts/release.sh        # → dist/Crook-x.y.z.zip
```

There is no `.xcodeproj`. The app is built by `swiftc` from a shell script,
which is short enough to read and does exactly what it says.

---

## Connecting to another Mac

You need `ssh` to that machine to work from a terminal first — Crook runs the
system `ssh` and adds nothing of its own. On the far machine that means
**System Settings ▸ General ▸ Sharing ▸ Remote Login**.

Then in Crook, **Connect to a Machine…** and give it the host name. On first
connect Crook copies a ~150 KB helper to `~/.crook/` on that machine and runs
it over the SSH session; there is nothing to install by hand and nothing
listening on a port. If your key has a passphrase, Crook asks for it only when
`ssh` says it needs one.

Worth adding to your `~/.ssh/config`, if the machine is one you keep a terminal
open to anyway:

```
Host mac-mini
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

That lets Crook share a connection that is already open instead of building its
own — no second handshake and no second authentication.

## How it is put together

An AppKit shell hosting a `WKWebView` that runs CodeMirror 6.

The unusual choice is that **Swift owns the text**, not CodeMirror. The buffer
lives in an `NSMutableString`, UTF-16 indexed, LF-only; CodeMirror sends change
sets across per animation frame and is never handed the whole document except
at load. That is what makes byte-exact round-trips possible — the editor is a
view, and nothing re-serialises the file on save.

Markdown renders live, Typora-style: syntax marks hide as you type and reappear
when the caret enters the block. There is no preview pane and no mode switch.

AppKit owns every control. The web view contains none, in any state.

Every filesystem call goes through one small protocol with two implementations,
local and SSH-backed, which is what lets the same code serve both machines. The
remote half is tested against the real helper binary over a pipe — including
the whole fixture corpus read back byte-for-byte — so it does not need a second
Mac to verify.

---

## Licence

MIT — see [LICENSE](LICENSE). Bundled dependencies are listed in
[THIRD-PARTY.md](THIRD-PARTY.md).
