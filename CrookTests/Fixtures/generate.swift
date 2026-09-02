// generate.swift — rebuilds CrookTests/Fixtures/corpus from scratch.
//
//     swift CrookTests/Fixtures/generate.swift
//
// The corpus is a SYNTHETIC stand-in for a real machine's Claude Code files.
// Every name, project and path in it is invented. It reproduces the byte-level
// and shape-level properties measured on a real 270-file corpus, scaled down to
// something small enough to read and to commit:
//
//   * CRLF line endings, files with no final newline, trailing whitespace
//   * no BOM, no lone CR, no leading tabs, no mixed line endings
//   * astral (4-byte UTF-8) characters, so UTF-16 offsets and Swift.String
//     grapheme indexing disagree and the scanner's offset arithmetic is tested
//   * many files sharing a basename (SKILL.md, CLAUDE.md, settings.json)
//   * one ~1,500-line file as the performance fixture
//   * dead absolute paths under invented home directories, so the dead-path
//     scanner has true positives that are true on every machine
//   * paths that must NOT be flagged: fenced blocks, globs, ${VARS},
//     <placeholders>, URLs, prose after a space, command lines in backticks,
//     and live references that really do resolve inside the fixture
//
// corpus/home/ stands in for the user's home directory. The test harness points
// Paths.homeOverride at it, which is what makes the personal-scope roles
// (~/.claude/skills, ~/.claude/commands, ~/.claude/settings.json) and the "~/"
// path anchor testable without touching the machine running the suite.
//
// The generated files ARE committed. This script exists so they are
// reproducible and reviewable, not so anyone has to run it.

import Foundation

// MARK: - spec

struct FileSpec {
    let rel: String
    let body: String
    var crlf = false
    var finalNewline = true
}

var files: [FileSpec] = []

/// `@WS@` at the end of a line becomes two trailing spaces. Written as a
/// sentinel because trailing whitespace does not survive an editor round trip
/// in this source file.
func add(_ rel: String, crlf: Bool = false, finalNewline: Bool = true, _ body: String) {
    files.append(FileSpec(rel: rel, body: body, crlf: crlf, finalNewline: finalNewline))
}

// MARK: - home (stands in for ~)

add("home/.claude/CLAUDE.md", """
# Personal memory@WS@

Read in every session, in every project.

- Prefer the smallest change that makes the point.
- Never invent a file path. If it is not on disk, say so.
- The house release skill is at ~/.claude/skills/release-notes/SKILL.md and it
  is the one place release wording is decided.
- The retired note at /Users/nobody-here/Standards/house-style.md is gone; do
  not go looking for it.
""")

add("home/.claude/settings.json", """
{
  "permissions": {
    "allow": ["Bash(git status)", "Bash(git diff:*)"],
    "deny": ["Bash(rm -rf:*)"]
  },
  "env": {
    "EDITOR_THEME": "quiet"
  }
}
""")

// Machine-written exhaust. Crook hides it, so ReachClassifier.readsInstructions
// is false for it — the one file in the corpus the role gate excludes.
add("home/.claude/settings.local.json", finalNewline: false, """
{
  "permissions": {
    "allow": ["Bash(ls)"]
  }
}
""")

add("home/.claude/commands/standup.md", """
---
description: Write the daily standup from the last day of commits
---

# /standup@WS@

Read the commit log for the last 24 hours and write three lines: shipped,
in flight, blocked.

Settings that matter here live in ~/.claude/settings.json.

The archive of last year's standups was at
/Users/nobody-here/Archive/atlas/2019/decisions.md and is not coming back.
""")

add("home/.claude/commands/handoff.md", crlf: true, """
---
description: Write a handoff note for whoever picks this up next
---

# /handoff

Start from what ~/.claude/commands/standup.md produced, then add the context a
stranger would need.

Do not hardcode a skill path: they resolve at `~/.claude/skills/${NAME}/SKILL.md`.

Memory nodes live under `~/.claude/projects/<slug>/memory/`, which is a shape,
not a location.

Collect the public keys listed by `ls ~/.ssh/*.pub` if the handoff needs access.
""")

add("home/.claude/agents/scribe.md", finalNewline: false, """
---
name: scribe
description: Writes the summary: one paragraph, no bullets
---

You write summaries. One paragraph. No bullets, no headings, no preamble.

If the material does not support a paragraph, say what is missing instead.
""")

add("home/.claude/rules/prose.md", """
---
paths:
  - "**/*.md"
description: House prose rules
---

# Prose@WS@

- Short sentences. One idea each.
- No exclamation marks.
- Name the thing, then say what it does.

The longer guide used to be at /Users/nobody-here/Standards/house-style.md.
""")

add("home/.claude/skills/release-notes/SKILL.md", """
---
name: release-notes
description: Turn a changelog into release notes a human will actually read
---

# Release notes@WS@

Status markers used in this package: ✅ shipped, 🚧 in progress, 🗓️ scheduled.

Read the changelog, group by surface, and write one line per change.

## Steps

1. Read `references/api.md` for the surface list.
2. Follow `commands/decide.md` to pick what is worth mentioning.
3. Fill in `templates/entry.md` once per surface.

## Do not do this

```bash
cp /Users/nobody-here/Projects/atlas-relay/scripts/seed.sh ./scripts/
./scripts/seed.sh --env prod
```

That block is an example of what went wrong last time, not an instruction.
""")

add("home/.claude/skills/release-notes/commands/decide.md", finalNewline: false, """
# Decide

A change is worth mentioning when at least one holds:

- Someone outside the team can see it.
- It changes a default.
- It removes something people were relying on.

Everything else is noise. 🚧
""")

add("home/.claude/skills/release-notes/references/api.md", crlf: true, """
# Surfaces

| Surface | Owner | Notes |
| --- | --- | --- |
| ingest | atlas-relay | Sealed segments only |
| status | beacon-shop | Rendered server-side |
| batch | cinder-mill | Overnight, retried once |

Older surface notes were elided into `~/.claude/.../archive/api.md` and that
path is a template, not a file.
""")

add("home/.claude/skills/release-notes/templates/entry.md", finalNewline: false, """
## <surface>

- **What changed:** <one sentence>
- **Why it matters:** <one sentence>
- **Upgrade note:** <optional, omit the bullet entirely if there is none>
""")

// The directory names the command. `name:` here deliberately disagrees.
add("home/.claude/skills/seed-check/SKILL.md", """
---
name: seed-checker
description: Verify a seeded environment before the first deploy
disable-model-invocation: true
---

# Seed check

The directory is what names the command. The `name:` field above says
`seed-checker` and moves nothing.

1. Confirm every table has a row count above zero.
2. Confirm the ledger head matches the segment index.
3. Confirm the wire version is the one the spec names.
""")

// Memory nodes. No reach sentence — nothing about their path is worth stating —
// but their contents are injected into context, so a dead path here is exactly
// as broken as one in a slash command. These are what the role gate must not
// hide.
add("home/.claude/projects/-corpus-atlas-relay/memory/MEMORY.md", """
# Atlas Relay — working memory

- The seed script at /Users/nobody-here/Projects/atlas-relay/scripts/seed.sh is
  still named by three commands and no longer exists.
- Decisions from 2019 are archived at /Users/nobody-here/Archive/atlas/2019/decisions.md
- Nothing in this file has a reach sentence, which is exactly why the scanner
  must not be gated on having one.
""")

add("home/.claude/projects/-corpus-cinder-mill/memory/notes.md", finalNewline: false, """
# Cinder Mill — working memory

- The batch window moved to 02:00 local and nobody updated the runbook.
- The old note at /Users/ghost-user/Notes/cinder/open.md is gone.
- Everything under /Users/ is off limits to the batch user.
""")

// MARK: - projects/atlas-relay

add("projects/atlas-relay/CLAUDE.md", """
# Atlas Relay@WS@

Atlas Relay moves signed payloads between the ingest edge and the ledger.

## House rules

- Every schema change ships with a migration and a rollback note.
- The seed script at `/Users/nobody-here/Projects/atlas-relay/scripts/seed.sh`
  is run once per environment.
- The wire format is documented in /Users/nobody-here/Projects/atlas-relay/docs/spec.md

## Local setup

```bash
cp /Users/nobody-here/Projects/atlas-relay/scripts/seed.sh ./scripts/
./scripts/seed.sh --env local
```

The block above is fenced, so nothing in it is a live reference.
""")

add("projects/atlas-relay/README.md", finalNewline: false, """
# Atlas Relay

Prose for humans. Claude Code still reads it, which is why a stale reference
here is worth catching even though the file has no reach sentence.

The previous README was moved to /Users/nobody-here/Projects/atlas-relay/README-old.md
and never came back.

See https://example.com/Users/atlas/rollout.md for the public writeup.
""")

add("projects/atlas-relay/.claude/settings.json", """
{
  "permissions": {
    "allow": ["Bash(swift build)", "Bash(swift test)"]
  },
  "env": {
    "ATLAS_ENV": "local"
  }
}
""")

add("projects/atlas-relay/.claude/commands/ship.md", """
---
description: Cut a release and push the tag
argument-hint: [version]
---

# /ship@WS@

1. Confirm the tree is clean.
2. Run the seed script at `/Users/nobody-here/Projects/atlas-relay/scripts/seed.sh` once.
3. Copy the checklist from `/Users/nobody-here/Notes/Field Notes/atlas/rollout.md`.
4. Tag, push, and announce.

Do not run `~/venvs/atlas/bin/pytest tests/ -q` here; CI owns the suite.
""")

add("projects/atlas-relay/.claude/commands/audit.md", crlf: true, """
---
description: Audit the ledger for unbalanced entries
---

# /audit

Walk every ledger segment and report any entry whose signature does not verify.

- Read the segment index first.
- Report in the order segments were written, never sorted.
- Stop at the first unreadable segment and say which one.
""")

add("projects/atlas-relay/.claude/commands/rollback.md", """
---
description: Roll a bad release back to the previous tag
---

# /rollback

Print the report with `/Users/ghost-user/bin/mill-report` before you touch the
tag, then:

- Move the tag back one release.
- Re-run /audit.
- Post the diff summary in the release channel.
""")

add("projects/atlas-relay/.claude/agents/reviewer.md", """
---
name: reviewer
description: Reviews diffs for correctness before they merge
---

You review diffs.@WS@

Read the wire format at /Users/nobody-here/Projects/atlas-relay/docs/spec.md
before commenting on anything under the ingest edge.

Report findings as a numbered list. Never edit files.
""")

// Frontmatter that is NOT at byte 0 — one blank line ahead of the opener, which
// is the way this defect actually shows up. Claude Code reads frontmatter only
// when the opening `---` is the file's first line, so this agent has no name as
// far as Claude Code is concerned, and Crook has to say so. Frontmatter.misplaced
// is true here.
add("projects/atlas-relay/.claude/agents/drafter.md", finalNewline: false, """

---
name: drafter
description: Drafts release notes from the changelog
---

Draft release notes from the changelog. Keep them short.
""")

add("projects/atlas-relay/.claude/rules/style.md", finalNewline: false, """
---
paths:
  - "**/*.swift"
description: Swift style for this project
---

# Swift style

- Four-space indents in Swift, two in JSON.
- No force unwraps outside tests.
- The house style guide is at /Users/nobody-here/Standards/house-style.md
""")

add("projects/atlas-relay/.claude/rules/naming.md", crlf: true, """
---
description: Naming conventions
---

# Naming

Segments are named after the hour they were sealed, never after the writer.
A renamed segment is a new segment; there is no rename.
""")

add("projects/atlas-relay/.claude/skills/chart-audit/SKILL.md", """
---
name: chart-audit
description: Check a chart against the house palette and axis rules
---

# Chart audit@WS@

Compare every series colour against
`/Users/nobody-here/Projects/beacon-shop/palette/tokens.json`.

Rules:

- No more than six categorical colours in one chart.
- Axes start at zero unless the caption says otherwise.
- One encoding per variable.
""")

add("projects/atlas-relay/.claude/skills/chart-audit/references/palette.md", """
# Palette

| Token | Light | Dark |
| --- | --- | --- |
| series-1 | #2f6f4e | #7fd1a5 |
| series-2 | #4a4f8c | #9aa0e0 |
| series-3 | #8a5a2b | #e0b184 |

Tokens are frozen. Adding one needs a design review.
""")

// Astral characters ahead of a dead path: the reported offsets are UTF-16 code
// units, which Swift.String's grapheme indexing would get wrong here.
add("projects/atlas-relay/docs/CLAUDE.md", finalNewline: false, """
# Docs

Status markers: ✅ shipped, 🚧 in progress, 🗓️ scheduled, 🧭 under discussion.

Formal notation uses 𝔄 for the ingest alphabet and 𝔅 for the ledger alphabet,
with 𝕊 for the sealed set. 🚧

The first spec revision was at /Users/nobody-here/Projects/atlas-relay/docs/spec-v1.md
and was folded into the current one.
""")

// MARK: - projects/beacon-shop

add("projects/beacon-shop/CLAUDE.md", crlf: true, """
# Beacon Shop@WS@

Beacon Shop renders the public status page.

- The cache manifest is written to /Users/ghost-user/Library/Caches/beacon/manifest.json
- Never commit rendered output.

There is an AGENTS.md beside this file. Claude Code does not read it.
""")

add("projects/beacon-shop/CLAUDE.local.md", finalNewline: false, """
# Local notes

Render against the staging bucket, not production.

This file is local to one checkout and is not shared.
""")

add("projects/beacon-shop/AGENTS.md", """
# Agents

This file exists for tools that read AGENTS.md. Claude Code reads CLAUDE.md,
and the CLAUDE.md beside this one does not import it.
""")

add("projects/beacon-shop/.claude/settings.json", """
{
  "permissions": {
    "allow": ["Bash(npm run build)"]
  }
}
""")

add("projects/beacon-shop/.claude/commands/deploy.md", """
---
description: Publish the status page
---

# /deploy

1. Build.
2. Upload to the bucket.
3. Purge the edge cache.
4. Run /smoke.
""")

add("projects/beacon-shop/.claude/commands/smoke.md", crlf: true, """
---
description: Smoke-test the published page
---

# /smoke

Fetch the page, assert the build id changed, and assert the feed parses.

Report the build id you saw, not the one you expected.
""")

add("projects/beacon-shop/packages/web/CLAUDE.md", crlf: true, finalNewline: false, """
# Web package

The renderer is a single binary. Templates live beside it.

Do not add a build step here without updating the root CLAUDE.md.
""")

add("projects/beacon-shop/notes/decisions.md", finalNewline: false, """
# Decisions

- The status page renders server-side. No client framework.
- The palette is frozen; changes need a design review.
- Retries are the renderer's problem, not the uploader's.
""")

// MARK: - projects/cinder-mill

add("projects/cinder-mill/CLAUDE.md", """
# Cinder Mill@WS@

@AGENTS.md

Cinder Mill batches overnight reports. The AGENTS.md beside this file is
imported above, so Claude Code reads it after all.
""")

add("projects/cinder-mill/AGENTS.md", crlf: true, """
# Agents

- Batches run at 02:00 local.
- A failed batch is retried once, then reported.
- A batch never rewrites a sealed segment.
""")

add("projects/cinder-mill/skills/lint-pass/SKILL.md", """
---
name: lint-pass
description: Run the house linter over a changed file set
---

# Lint pass

This package sits outside `.claude/skills`, so Claude Code never scans it and
the command it looks like it defines does not exist.

Rules are loaded from /Users/ghost-user/Projects/cinder-mill/lint/rules.yaml
""")

add("projects/cinder-mill/skills/lint-pass/references/rules.md", finalNewline: false, """
# Rules

- R1 — no trailing whitespace in generated files.
- R2 — no tab indentation anywhere.
- R3 — every file ends with a newline unless it is deliberately a fixture.
""")

add("projects/cinder-mill/skills/tone-guide/SKILL.md", """
---
name: tone-guide
description: House voice for anything a customer reads
---

# Tone

Short sentences. No exclamation marks. Name the thing, then say what it does.

Never apologise for the software in the software.
""")

add("projects/cinder-mill/skills/tone-guide/templates/memo.md", finalNewline: false, """
# <title>

**What happened.** <one paragraph>

**What we changed.** <one paragraph>

**What to watch.** <one line>
""")

// MARK: - the performance fixture

var big = """
---
name: reference-corpus
description: A long reference the editor loads to measure the keystroke path
---

# Reference corpus@WS@

Status markers: ✅ settled, 🚧 open, 🗓️ scheduled.

Formal notation uses 𝔄 for the input alphabet, 𝔅 for the output alphabet, and
𝕊 for the sealed set.

Rules are numbered from R0001 upward and are never renumbered.


"""

for i in 1...186 {
    let id = String(format: "R%04d", i)
    big += """
    ## \(id)

    Rule \(id) applies when the segment header is present and the payload
    length is a multiple of eight. 🚧

    - Precondition: the previous segment sealed cleanly.
    - Action: append, never rewrite.


    """
}

big += """
## Provenance

These rules were extracted from an index at
/Users/ghost-user/Projects/reference-corpus/index.md which no longer exists.

"""

add("perf/large-skill/SKILL.md", big)

add("perf/large-skill/references/index.md", finalNewline: false, """
# Index

The rule entries in SKILL.md are numbered R0001 upward and never renumbered.

A retired rule keeps its number and gains a 🗓️ marker.
""")

// MARK: - write

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("corpus", isDirectory: true)

let fm = FileManager.default
try? fm.removeItem(at: root)
try fm.createDirectory(at: root, withIntermediateDirectories: true)

var written: [String] = []

for spec in files {
    var body = spec.body.replacingOccurrences(of: "@WS@", with: "  ")
    if !spec.finalNewline {
        while body.hasSuffix("\n") { body.removeLast() }
    } else if !body.hasSuffix("\n") {
        body += "\n"
    }
    if spec.crlf {
        body = body.replacingOccurrences(of: "\n", with: "\r\n")
    }

    let url = root.appendingPathComponent(spec.rel)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = body.data(using: .utf8) else {
        fatalError("not UTF-8 encodable: \(spec.rel)")
    }
    try data.write(to: url)
    written.append(spec.rel)
}

// The frozen list the suite iterates. Paths are relative to the Fixtures
// directory so the checked-in file is identical on every machine.
let list = written.map { "corpus/" + $0 }.sorted().joined(separator: "\n") + "\n"
try list.write(to: root.deletingLastPathComponent().appendingPathComponent("corpus.txt"),
               atomically: true, encoding: .utf8)

print("wrote \(written.count) files under \(root.path)")
