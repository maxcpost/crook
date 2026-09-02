import Foundation

/// S1 — frontmatter that Claude Code cannot read.
///
/// Two silent failures, one channel each. A block whose YAML does not parse
/// gets an underline on the exact character the parser objects to; a block that
/// is not the file's first line gets a sentence in the reach readout, because
/// its consequence is about how the whole file is READ.
///
/// Every fixture here is inline. The shared corpus is a frozen list of paths on
/// one machine, and a rule about false positives cannot be argued from a corpus
/// that may not be present.
enum ValidationTests {

    /// Wrap a block in markers, the way a real file carries it.
    private static func fm(_ body: String) -> String {
        "---\n\(body)\n---\n\n# Body\n\nSome prose.\n"
    }

    private static func problems(_ body: String) -> [FrontmatterValidator.Problem] {
        FrontmatterValidator.validate(fm(body))
    }

    /// The substring an underline actually covers — the whole point of the
    /// feature is that this is the offending token and nothing else.
    private static func marked(_ text: String, _ p: FrontmatterValidator.Problem) -> String {
        let u = Array(text.utf16)
        guard p.from >= 0, p.to <= u.count, p.to > p.from else { return "" }
        return String(decoding: u[p.from..<p.to], as: UTF16.self)
    }

    static func run() {
        yaml()
        quiet()
        displaced()
        wiring()
    }

    // MARK: - V1 — the defect that costs three skills

    static func yaml() {
        T.suite("validation — YAML that does not parse")

        // The real shape, reduced: an unquoted description with a colon in it.
        // PyYAML on this exact construct: "mapping values are not allowed
        // here", with the caret on the second colon.
        let one = problems("name: reviewer\ndescription: Use when reviewing code. Example: a pull request")
        T.eq("V1-a  one problem", one.count, 1)
        T.ok("V1-b  it is the colon rule", one.first?.kind == .colon)
        T.eq("V1-c  the mark covers the offending colon and its space",
             marked(fm("name: reviewer\ndescription: Use when reviewing code. Example: a pull request"), one[0]), ": ")

        // The exact character, not merely the right line.
        let text = fm("name: reviewer\ndescription: Use when reviewing code. Example: a pull request")
        let want = (text as NSString).range(of: "Example:").location + 7
        T.eq("V1-d  it lands on THAT colon, not the first one on the line", one[0].from, want)

        // A colon at end of line is the same error.
        let eol = problems("name: a\ndescription: Steps:")
        T.eq("V1-e  a trailing colon is flagged too", eol.count, 1)
        T.eq("V1-f  and the mark is one character", marked(fm("name: a\ndescription: Steps:"), eol[0]), ":")

        // A tab in indentation.
        let tab = problems("name: a\nallowed-tools:\n\t- Read")
        T.eq("V1-g  a tab in indentation is flagged", tab.count, 1)
        T.ok("V1-h  as the tab rule", tab.first?.kind == .tab)
        T.eq("V1-i  and the mark is the tab itself", marked(fm("name: a\nallowed-tools:\n\t- Read"), tab[0]), "\t")

        // A quote with no partner anywhere in the block.
        let q = problems("name: a\ndescription: \"never closed")
        T.eq("V1-j  an unterminated quote is flagged", q.count, 1)
        T.ok("V1-k  as the quote rule", q.first?.kind == .unterminatedQuote)
        T.eq("V1-l  and the mark is the quote", marked(fm("name: a\ndescription: \"never closed"), q[0]), "\"")

        // A single quote opening a value is a quote, not an apostrophe.
        let sq = problems("name: a\ndescription: 'twas the night")
        T.eq("V1-m  an unterminated single quote too", sq.count, 1)

        // Duplicate top-level key.
        let dup = problems("name: first\ndescription: x\nname: second")
        T.eq("V1-n  a duplicate top-level key is flagged", dup.count, 1)
        T.ok("V1-o  as the duplicate rule", dup.first?.kind == .duplicateKey("name"))
        T.eq("V1-p  the mark is on the SECOND one",
             dup[0].from, (fm("name: first\ndescription: x\nname: second") as NSString)
                 .range(of: "name: second").location)

        // The mechanism the underline rides on drops an empty or reversed
        // range silently, which would look exactly like "nothing is wrong".
        T.ok("V1-q  every range is non-empty",
             (one + eol + tab + q + sq + dup).allSatisfy { $0.from >= 0 && $0.to > $0.from })

        // Nested values are parsed too, and break the same way.
        let nested = problems("name: a\nmetadata:\n  note: see also: here")
        T.eq("V1-r  a nested unquoted value is flagged", nested.count, 1)

        // A more-indented line under a plain scalar is part of THAT scalar, and
        // a mapping indicator inside it is the same error. PyYAML agrees.
        let cont = problems("name: a\ndescription: a long line\n  continued: badly")
        T.eq("V1-s  a continuation line is flagged", cont.count, 1)

        // Two defective fields, two marks — one per value, never one per colon.
        let two = problems("name: a: b\ndescription: c: d: e")
        T.eq("V1-t  one mark per broken value, not per colon", two.count, 2)
        T.ok("V1-u  in document order", two[0].from < two[1].from)

        // The tooltip has to name the problem and the fix, or the mark is just
        // a red squiggle.
        T.ok("V1-v  the colon tooltip names the fix", one[0].title.contains("quote it"))
        T.ok("V1-w  and leads with the consequence",
             one[0].title.hasPrefix("Frontmatter does not parse"))
    }

    // MARK: - V2 — everything correct, and therefore silent

    static func quiet() {
        T.suite("validation — correct frontmatter draws nothing")

        // A rule that flags correct code trains the reader to ignore the
        // channel. These are the constructs a colon rule gets wrong.
        let clean: [(String, String)] = [
            ("a quoted colon",        "name: a\ndescription: \"Use it: like this\""),
            ("a single-quoted colon", "name: a\ndescription: 'Use it: like this'"),
            ("a URL",                 "name: a\nhome: https://example.com/a/b"),
            ("a bare time",           "name: a\nat: 10:30 tomorrow"),
            ("an apostrophe",         "name: a\ndescription: don't do it"),
            ("a hash inside a word",  "name: a\ntag: c#sharp"),
            ("a comment",             "name: a\ndescription: hi # note: ignored"),
            ("a literal block",       "name: a\ndescription: |\n  Use it: like this\n  more: here"),
            ("a folded block",        "name: a\ndescription: >\n  Use it: like this"),
            ("a nested map",          "name: a\nmetadata:\n  version: 1\n  author: max"),
            ("a block sequence",      "name: a\npaths:\n  - src/**\n  - test: fixtures"),
            ("a flow sequence",       "name: a\npaths: [\"x: y\", z]"),
            ("a flow map",            "name: a\nm: {x: 1, y: 2}"),
            ("a multi-line quote",    "name: a\ndescription: \"one\n  two: three\""),
            ("an escaped quote",      "name: a\ndescription: \"say \\\"hi\\\"\""),
            ("a doubled quote",       "name: a\ndescription: 'it''s fine'"),
            ("a plain continuation",  "name: a\ndescription: one\n  two three"),
            ("an empty value",        "name: a\ndescription:"),
            ("a tool pattern",        "name: a\nallowed-tools: Bash(git:*), Read"),
            ("an anchor",             "name: &n a\nother: *n"),
            ("a nested duplicate",    "name: a\nx:\n  k: 1\ny:\n  k: 2"),
            ("a tab inside a block",  "name: a\ndescription: |\n  has\n  \tan indented tab"),
            ("an empty block",        ""),
        ]
        for (label, body) in clean {
            let got = problems(body)
            T.ok("V2    \(label) is silent", got.isEmpty,
                 "got \(got.count): \(got.first.map { $0.title } ?? "")")
        }

        // No frontmatter at all, and frontmatter Claude Code will not read.
        T.ok("V2-x  a file with no frontmatter is silent",
             FrontmatterValidator.validate("# Heading\n\nSome: prose here.\n").isEmpty)
        T.ok("V2-y  a displaced block is left to the readout",
             FrontmatterValidator.validate("\n---\nname: a: b\n---\n").isEmpty)
        T.ok("V2-z  an unclosed block is silent",
             FrontmatterValidator.validate("---\nname: a: b\n\n# no closer\n").isEmpty)

        // The one real defect in this machine's ~/.claude, reduced to its
        // shape. PyYAML puts its caret on the colon after `Context`.
        let real = "---\nname: silent-failure-hunter\ndescription: Use this agent when reviewing code. Examples:\\n\\n<example>\\nContext: Daisy has just finished implementing a feature.\nmodel: inherit\n---\n"
        let got = FrontmatterValidator.validate(real)
        T.eq("V2-1  the real defect is found exactly once", got.count, 1)
        T.eq("V2-2  on the colon after Context",
             got.first?.from, (real as NSString).range(of: "Context:").location + 7)
        T.ok("V2-3  and NOT on the escaped Examples:\\n",
             (got.first?.from ?? 0) > (real as NSString).range(of: "Examples:").location)
    }

    // MARK: - V3 — frontmatter that is not the first line

    static func displaced() {
        T.suite("validation — frontmatter that is not the first line")

        let good = "---\nname: reviewer\ndescription: x\n---\n\n# Body\n"
        T.ok("V3-a  a correct file is not displaced", !Frontmatter(good).misplaced)

        let cases: [(String, String)] = [
            ("a leading blank line", "\n---\nname: reviewer\n---\n"),
            ("a leading space",      " ---\nname: reviewer\n---\n"),
            ("a UTF-8 BOM",          "\u{FEFF}---\nname: reviewer\n---\n"),
            ("a leading tab",        "\t---\nname: reviewer\n---\n"),
            ("two blank lines",      "\n\n---\nname: reviewer\n---\n"),
        ]
        for (label, text) in cases {
            T.ok("V3    \(label) displaces the block", Frontmatter(text).misplaced)
            T.ok("V3    \(label) also hides the fields", Frontmatter(text).value("name") == nil)
        }

        // The false positives that made the old flag unusable. Each of these
        // is ordinary markdown, and each fired under the previous rule.
        let innocent: [(String, String)] = [
            ("a setext heading",     "Title\n---\n\nBody text.\n"),
            ("a horizontal rule",    "# Title\n\nRepository: x\n\n---\n\n## Next\n"),
            ("a rule after a blank", "\n# Title\n\n---\n\n## Next\n"),
            ("a table of dashes",    "| a | b |\n| --- | --- |\n| 1 | 2 |\n"),
            ("two rules in a row",   "\n---\n\n---\n\nBody.\n"),
            ("a rule then prose",    "\n---\nJust some prose, no colon key.\n---\n"),
            ("plain prose",          "Some text.\n\nMore text.\n"),
            ("an empty file",        ""),
        ]
        for (label, text) in innocent {
            T.ok("V3    \(label) is NOT displaced", !Frontmatter(text).misplaced)
        }

        // The sentence. It has to say what the consequence IS, and it has to
        // replace the field-derived claim rather than sit beside it.
        let H = Paths.home
        let agent = URL(fileURLWithPath: "\(H)/.claude/agents/reviewer.md")
        let displacedAgent = "\n---\nname: reviewer\ndescription: x\n---\n\nBody.\n"
        let s = ReachClassifier.subtitle(for: agent, text: displacedAgent)
        T.ok("V3-x  the readout carries the consequence",
             s.contains("frontmatter is not the first line") && s.contains("reads the whole file as content"), s)
        T.ok("V3-y  and does NOT claim the name field is missing",
             !s.contains("no name: field"), s)
        T.ok("V3-z  a correct agent still reads normally",
             ReachClassifier.subtitle(for: agent, text: "---\nname: reviewer\n---\n")
                 .contains("delegates to reviewer"))

        let skill = URL(fileURLWithPath: "\(H)/.claude/skills/release-notes/SKILL.md")
        let ds = ReachClassifier.subtitle(for: skill, text: displacedAgent)
        T.ok("V3-1  a skill keeps the half its PATH still guarantees",
             ds.hasPrefix("Personal skill · /release-notes"), ds)
        T.ok("V3-2  and gains the consequence", ds.contains(ReachClassifier.displacedClause))
    }

    // MARK: - V4 — the wiring

    static func wiring() {
        T.suite("validation — the wiring")

        let H = Paths.home
        // Only where Claude Code parses a header. A memory file's `---` block
        // is prose, and so is a package reference file's.
        T.ok("V4-a  a SKILL.md is checked",
             ReachClassifier.parsesFrontmatter(URL(fileURLWithPath: "\(H)/.claude/skills/release-notes/SKILL.md")))
        T.ok("V4-b  a subagent is checked",
             ReachClassifier.parsesFrontmatter(URL(fileURLWithPath: "\(H)/.claude/agents/a.md")))
        T.ok("V4-c  a command is checked",
             ReachClassifier.parsesFrontmatter(URL(fileURLWithPath: "\(H)/.claude/commands/c.md")))
        T.ok("V4-d  a memory file is NOT",
             !ReachClassifier.parsesFrontmatter(URL(fileURLWithPath: "\(H)/.claude/CLAUDE.md")))
        T.ok("V4-e  settings.json is NOT",
             !ReachClassifier.parsesFrontmatter(URL(fileURLWithPath: "\(H)/.claude/settings.json")))

        // The keystroke path is measured at under 11 µs and the check is far
        // heavier than that, so it must not be reachable from the sentence.
        let clean = fm("name: release-notes\ndescription: A skill that does a thing")
        let broken = fm("name: release-notes\ndescription: A skill: that does a thing")
        let ctx = ReachClassifier.Context.resolve(
            URL(fileURLWithPath: "\(H)/.claude/skills/release-notes/SKILL.md"))
        T.eq("V4-f  a YAML defect does not change the reach sentence",
             ReachClassifier.subtitle(ctx, text: broken),
             ReachClassifier.subtitle(ctx, text: clean))

        // And the sentence still costs what it cost. Same shape as G5-a.
        let N = 2000
        let t0 = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for _ in 0..<N { sink += ReachClassifier.subtitle(ctx, text: broken).count }
        let per = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(N) / 1000.0
        T.ok("V4-g  the keystroke path is still under 11 µs", per < 11.0, String(format: "%.2f µs", per))
        T.ok("V4-h  it computed something", sink > 0)

        // A document-sized block is not frontmatter. Draw nothing rather than
        // walk it.
        let huge = "---\n" + String(repeating: "k: a: b\n", count: 8000) + "---\n"
        T.ok("V4-i  a pathological block draws nothing", FrontmatterValidator.validate(huge).isEmpty)

        // Offsets are UTF-16 into the whole document, the same space CM6 uses.
        // A non-BMP character before the defect must not shift the mark.
        let astral = "---\nname: \u{1F600}\ndescription: a: b\n---\n"
        let p = FrontmatterValidator.validate(astral)
        T.eq("V4-j  one problem past an astral character", p.count, 1)
        T.eq("V4-k  at the UTF-16 offset of its colon",
             p.first?.from, (astral as NSString).range(of: "a: b").location + 1)

        // The scan is bounded, so a broken file cannot flood the channel.
        let many = "---\n" + (0..<40).map { "k\($0): a: b" }.joined(separator: "\n") + "\n---\n"
        T.ok("V4-l  the mark count is capped", FrontmatterValidator.validate(many).count <= 16)
    }
}
