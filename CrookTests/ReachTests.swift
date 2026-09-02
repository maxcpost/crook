import Foundation

enum ReachTests {
    static func run() {
        T.suite("reach — the shared classifier")
        census()
        sentences()
    }

    /// The census. Runs under the corpus's own home: the fixture's `home/` for
    /// the synthetic corpus, the machine's for a CROOK_CORPUS one.
    private static func census() {
        T.withCorpusHome {
            var withSentence = 0, silent = 0
            var buckets: [String: Int] = [:]
            for p in T.fixture {
                let s = ReachClassifier.subtitle(for: URL(fileURLWithPath: p), text: T.read(p))
                if s.isEmpty { silent += 1; continue }
                withSentence += 1
                buckets[String(s.split(separator: "·").first!.trimmingCharacters(in: .whitespaces)), default: 0] += 1
            }
            if T.usingSyntheticCorpus {
                // Measured over the 43-file synthetic corpus. Every role the
                // classifier can reach from a path is represented.
                T.eq("T11a  files with a reach sentence", withSentence, 38)
                T.eq("T11b  correctly silent", silent, 5)
                T.eq("T11c  supporting files", buckets["Supporting file"] ?? 0, 7)
                T.eq("T11d  project commands", buckets["Project command"] ?? 0, 5)
                T.eq("T11e  skills nothing scans", buckets["Not in a directory Claude Code scans for skills"] ?? 0, 3)
                T.eq("T11f  project memory", buckets["Project memory"] ?? 0, 5)
                T.eq("T11g  project skills", buckets["Project skill"] ?? 0, 1)
                T.eq("T11h  personal skills", buckets["Personal skill"] ?? 0, 2)
                T.eq("T11i  personal commands", buckets["Personal command"] ?? 0, 2)
                T.eq("T11j  subagents", buckets["Subagent"] ?? 0, 3)
                T.eq("T11k  project settings", buckets["Project settings"] ?? 0, 2)
                T.eq("T11l  rules, personal and project",
                     (buckets["Personal rule"] ?? 0) + (buckets["Project rule"] ?? 0), 3)
            } else {
                print("  ..   T11* skipped: CROOK_CORPUS names a different corpus")
            }

            // T13 — readsInstructions is NOT "has a sentence". Deriving one from
            // the other silences the scanner on every file whose path says
            // nothing worth saying, and memory nodes are exactly those files:
            // 3 of this corpus's 5 silent files carry 4 of its 19 dead
            // references between them.
            let reads = T.fixture.filter { ReachClassifier.readsInstructions(URL(fileURLWithPath: $0)) }.count
            T.ok("T13   readsInstructions is broader than hasSentence", reads > withSentence,
                 "reads \(reads), sentences \(withSentence)")
        }
    }

    /// Assertions about specific fixture files. Always under the fixture's home
    /// — these files are the subject, not whatever corpus was selected.
    private static func sentences() {
        T.withFixtureHome {
            func sub(_ p: String) -> String {
                ReachClassifier.subtitle(for: URL(fileURLWithPath: p), text: T.read(p))
            }
            let H = Paths.home

            T.eq("T01   personal skill names its command from the DIRECTORY",
                 sub("\(H)/.claude/skills/release-notes/SKILL.md"), "Personal skill · /release-notes")
            // The fixture's seed-check package says `name: seed-checker` on disk
            // and still answers /seed-check: the directory names the command.
            T.eq("T03   disable-model-invocation appends the clause",
                 sub("\(H)/.claude/skills/seed-check/SKILL.md"),
                 "Personal skill · /seed-check · you invoke it, Claude can't")
            T.eq("T04   a package's supporting file says so",
                 sub("\(H)/.claude/skills/release-notes/commands/decide.md"),
                 "Supporting file · read only when the package names it")
            T.eq("T05   personal settings", sub("\(H)/.claude/settings.json"),
                 "Personal settings · read in every session")

            // T09 — editing `name:` must move nothing. Same rule as T03, against
            // a buffer that was just edited rather than against the file.
            let base = "---\nname: something-else\ndescription: x\n---\n# hi\n"
            let u = URL(fileURLWithPath: "\(H)/.claude/skills/release-notes/SKILL.md")
            T.eq("T09   `name:` does not change the command",
                 ReachClassifier.subtitle(for: u, text: base), "Personal skill · /release-notes")

            // T08 — the clause flips on the keystroke that completes the value.
            let pre = "---\ndisable-model-invocation: tru\n---\n"
            let post = "---\ndisable-model-invocation: true\n---\n"
            T.ok("T08a  incomplete value shows no clause",
                 !ReachClassifier.subtitle(for: u, text: pre).contains("you invoke it"))
            T.ok("T08b  the final 'e' flips it",
                 ReachClassifier.subtitle(for: u, text: post).contains("you invoke it, Claude can't"))

            // T14/T15 — the same skill rule one directory out, and outside every
            // directory that is scanned at all.
            T.eq("T14   a project skill is scanned and named the same way",
                 sub(T.f("projects/atlas-relay/.claude/skills/chart-audit/SKILL.md")),
                 "Project skill · /chart-audit")
            T.eq("T15   a SKILL.md outside a scanned directory says so",
                 sub(T.f("projects/cinder-mill/skills/lint-pass/SKILL.md")),
                 "Not in a directory Claude Code scans for skills")

            // T16 — frontmatter that is not at byte 0. The fixture's drafter.md
            // carries a `name:` field Claude Code will never read, so the
            // sentence has to describe the file as Claude Code sees it rather
            // than as it looks.
            let drafter = sub(T.f("projects/atlas-relay/.claude/agents/drafter.md"))
            T.ok("T16a  a displaced block does not claim the name field is missing",
                 !drafter.contains("no name: field"), drafter)
            T.ok("T16b  and does not read the name it can see",
                 !drafter.contains("drafter"), drafter)
            T.eq("T16c  a subagent with real frontmatter still resolves",
                 sub("\(H)/.claude/agents/scribe.md"), "Subagent · Claude delegates to scribe")

            // T17 — AGENTS.md, both ways round, decided by the sibling CLAUDE.md.
            T.eq("T17a  AGENTS.md alone is not read",
                 sub(T.f("projects/beacon-shop/AGENTS.md")),
                 "Claude Code reads CLAUDE.md, not AGENTS.md")
            T.eq("T17b  AGENTS.md imported by the CLAUDE.md beside it is",
                 sub(T.f("projects/cinder-mill/AGENTS.md")),
                 "Read through the CLAUDE.md beside it")

            // The empty state is a decision, not an accident.
            T.eq("T12   a file outside every role is silent",
                 ReachClassifier.subtitle(for: URL(fileURLWithPath: "/tmp/whatever.md"), text: "# x"), "")
        }
    }
}

extension ReachTests {
    /// G5 — the keystroke path must not touch the disk, and must be fast.
    /// Measured on the corpus's largest file (1,507 lines), because the whole
    /// point of the frontmatter cap is that cost does not track file size.
    static func perf() {
        T.withFixtureHome {
            T.suite("reach — the keystroke path")
            let u = URL(fileURLWithPath: T.f("perf/large-skill/SKILL.md"))
            let text = T.read(u.path)
            let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
            T.ok("G5-0  the performance fixture is the large one",
                 lineCount > 1400, "\(lineCount) lines")

            // Resolving is allowed to probe. Using the result is not.
            let ctx = ReachClassifier.Context.resolve(u)
            let N = 2000
            let t0 = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<N { sink += ReachClassifier.subtitle(ctx, text: text).count }
            let per = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(N) / 1000.0
            T.ok("G5-a  pure subtitle is under 11 µs per keystroke",
                 per < 11.0, String(format: "%.2f µs", per))
            T.ok("G5-b  it actually computed something", sink > 0)

            // Structural: the context carries the filesystem answers, so the
            // pure path cannot need them.
            T.ok("G5-c  the context holds the package answer", ctx.inPackage == false)
            T.eq("G5-d  the pure path agrees with the convenience path",
                 ReachClassifier.subtitle(ctx, text: text),
                 ReachClassifier.subtitle(for: u, text: text))
        }
    }
}
