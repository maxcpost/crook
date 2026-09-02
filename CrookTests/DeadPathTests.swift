import Foundation

enum DeadPathTests {
    static func run() {
        T.suite("deadpath — the scanner")
        census()
        rules()
    }

    /// The census. Runs under the corpus's own home, so a `~/` reference in a
    /// corpus file means what it means to whoever owns that corpus.
    private static func census() {
        T.withCorpusHome {
            // T-01 / T-14: the equality that proves the gate no longer hides
            // findings. Before the fix these differed. The synthetic corpus is
            // built to keep the difference reachable: 5 of its 43 files have no
            // reach sentence, and 3 of those carry 4 dead references between
            // them, so a gate derived from "has a sentence" would drop them and
            // the two counts would part company again.
            var gated: [PathScanner.DeadPath] = [], ungated: [PathScanner.DeadPath] = []
            var filesWith = Set<String>()
            var offsetsSliceBack = true
            for p in T.fixture {
                let url = URL(fileURLWithPath: p)
                let text = T.read(p)
                let g = PathScanner.scan(text, url: url)
                let u = PathScanner.scan(text, url: url, roleGated: false)
                gated += g; ungated += u
                if !g.isEmpty { filesWith.insert(p) }

                // T-08 — offsets are UTF-16 code units into the document, the
                // same coordinate space as NSMutableString.length and CM6's
                // doc.length. Five corpus files carry astral characters ahead
                // of their dead path, which is exactly where Swift.String's
                // grapheme indexing would put the underline somewhere else.
                let units = Array(text.utf16)
                for d in g {
                    guard d.from >= 0, d.to <= units.count, d.to > d.from else {
                        offsetsSliceBack = false; continue
                    }
                    let slice = String(utf16CodeUnits: Array(units[d.from..<d.to]), count: d.to - d.from)
                    if slice != d.path { offsetsSliceBack = false }
                }
            }
            T.ok("T-08  every finding's offsets slice back to the path it names", offsetsSliceBack)

            if T.usingSyntheticCorpus {
                T.eq("T-01  dead paths, role gate ON", gated.count, 19)
                T.eq("T-14  dead paths, role gate OFF  ← the equality", ungated.count, 19)
                T.eq("T-02  distinct dead paths", Set(gated.map(\.path)).count, 13)
                T.eq("T-05  distinct files", filesWith.count, 16)
            } else {
                print("  ..   T-01/02/05 counts skipped: CROOK_CORPUS names a different corpus")
                T.eq("T-14  dead paths, role gate OFF  ← the equality", ungated.count, gated.count)
            }

            // Every finding must genuinely be absent. Counting is not auditing —
            // a shipped total once read 20 while two errors cancelled inside it.
            var wronglyDead = 0
            for d in gated {
                let ex = d.path.hasPrefix("~/") ? Paths.home + String(d.path.dropFirst(1)) : d.path
                if FileManager.default.fileExists(atPath: ex) { wronglyDead += 1 }
            }
            T.eq("T-06  no live path is reported dead", wronglyDead, 0)
            T.ok("T-07  every finding says where the path stops existing",
                 gated.allSatisfy { $0.existsUpTo != nil })
        }
    }

    /// The rules themselves, against fixture files and inline cases.
    private static func rules() {
        T.withFixtureHome {
            // T-09 — the other direction: a reference in the corpus that DOES
            // resolve, and must therefore stay silent. Without one of these the
            // scanner could report every path it sees and still pass T-01.
            let live = T.read(T.f("home/.claude/CLAUDE.md"))
            T.ok("T-09  a live ~/ reference is not reported",
                 live.contains("~/.claude/skills/release-notes/SKILL.md")
                 && !PathScanner.scan(live, url: nil, roleGated: false)
                     .contains { $0.path.hasPrefix("~/") })

            func none(_ id: String, _ text: String) {
                T.ok(id, PathScanner.scan(text, url: nil, roleGated: false).isEmpty,
                     PathScanner.scan(text, url: nil, roleGated: false).map(\.path).description)
            }
            func count(_ id: String, _ text: String, _ n: Int) {
                T.eq(id, PathScanner.scan(text, url: nil, roleGated: false).count, n)
            }
            /// The exact path reported — where the run stopped, not merely how
            /// many runs there were.
            func says(_ id: String, _ text: String, _ want: String) {
                T.eq(id, PathScanner.scan(text, url: nil, roleGated: false).first?.path ?? "(none)", want)
            }

            none("T-17a elided segment is a template",  "read ~/.claude/.../memory/x.md")
            none("T-17b elided mid-path",               "see ~/.claude/projects/.../memory/")
            none("T-18  fenced block",   "```bash\nls /Users/nobody/gone/x.md\n```")
            none("T-19  glob",           "run `ls ~/.ssh/*.pub` now")
            none("T-20  shell variable", "read `~/.claude/skills/${NAME}/SKILL.md`")
            none("T-21  angle brackets", "see `~/.claude/projects/<slug>/memory/`")
            none("T-22  URL",            "https://example.com/Users/x/y.md")
            none("T-24  command in a code span", "`~/venvs/x/bin/pytest tests/ -q`")
            none("T-25  em dash ends the run", "/Users/nobody/gone\u{2014}iCloud")
            none("T-26  root only",      "everything under /Users/ is fine")
            none("T-27  tilde inside a word", "foo~/bar/baz.md")

            // T-23 — prose after a space is not part of the path. Asserted as
            // the boundary the run stopped at rather than as "nothing was
            // found": the old form used a real directory (~/Documents), so it
            // passed or failed on whether the machine running the suite
            // happened to have one, which said nothing about the space rule.
            says("T-23  prose after a space is not consumed",
                 "/Users/nobody-here/Notes stops the run before this prose",
                 "/Users/nobody-here/Notes")

            count("T-28  a plain dead path",
                  "instructions at /Users/nobody-here/Projects/thing/SKILL.md", 1)
            says("T-29  a space inside a directory name is consumed",
                 "See /Users/nobody-here/Notes/Field Notes/atlas/x.md now",
                 "/Users/nobody-here/Notes/Field Notes/atlas/x.md")
            count("T-30  two anchors are two findings, never one run",
                  "/Users/a/x.md and /Users/a/y.md", 2)
            count("T-31  a filename ends the path; prose after it is not consumed",
                  "see /Users/nobody/a.md and more stuff here", 1)

            // The role gate's own contract.
            T.ok("T-13  a markdown file Crook shows is read as instructions",
                 ReachClassifier.readsInstructions(
                    URL(fileURLWithPath: T.f("home/.claude/skills/release-notes/SKILL.md"))))
            T.ok("T-13b settings.local.json is machine exhaust, not instructions",
                 !ReachClassifier.readsInstructions(URL(fileURLWithPath: "/x/.claude/settings.local.json")))
            if T.usingSyntheticCorpus {
                T.ok("T-13c and the corpus contains one, so the gate is exercised",
                     T.fixture.contains { ($0 as NSString).lastPathComponent == "settings.local.json" })
            }
        }
    }
}
