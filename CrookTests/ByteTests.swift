import Foundation

/// The product's one non-negotiable claim.
enum ByteTests {
    static func run() {
        T.suite("bytes — golden-file round trip over the frozen fixture")
        var identical = 0, mismatched = 0
        var crlf = 0, noFinalNL = 0, bom = 0, loneCR = 0, mixed = 0
        var trailingWS = 0, leadingTab = 0, astral = 0
        var missing: [String] = []
        for p in T.fixture {
            guard let data = FileManager.default.contents(atPath: p) else { missing.append(p); continue }
            guard let (text, profile) = try? ByteCodec.decode(data) else { mismatched += 1; continue }
            if profile.lineEnding == .crlf { crlf += 1 }
            if profile.lineEnding == .cr { loneCR += 1 }
            if profile.mixedLineEndings { mixed += 1 }
            if !profile.hasFinalNewline { noFinalNL += 1 }
            if profile.bom != nil { bom += 1 }
            if (try? ByteCodec.encode(text, profile: profile)) == data { identical += 1 } else { mismatched += 1 }

            // Measured on the canonical LF-only buffer, so a CRLF file's "\r"
            // is not mistaken for trailing whitespace.
            let s = text as String
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.contains(where: { $0.hasSuffix(" ") || $0.hasSuffix("\t") }) { trailingWS += 1 }
            if lines.contains(where: { $0.hasPrefix("\t") }) { leadingTab += 1 }
            if s.unicodeScalars.contains(where: { $0.value > 0xFFFF }) { astral += 1 }
        }
        T.ok("B-00  the corpus was found", T.fixture.count > 0, "\(T.fixture.count) files")
        // A file the list names but the checkout does not have. Worth its own
        // assertion because the cause is never in this repository's code: a
        // global gitignore carrying `**/.claude/settings.local.json` drops one
        // of these on the way into the commit, and every count below then fails
        // by one with nothing to say why.
        T.ok("B-17  every file the list names is present", missing.isEmpty,
             "missing \(missing.count): \(missing.map { ($0 as NSString).lastPathComponent })")
        T.eq("B-01  every fixture file round-trips byte-identical", identical, T.fixture.count)
        T.eq("B-02  no mismatches", mismatched, 0)

        // Mixed endings cannot be reproduced by re-expanding one ending, so a
        // corpus containing any would make B-01 unachievable rather than merely
        // wrong. Asserting it separately keeps that failure legible.
        T.eq("B-12  no file mixes line endings", mixed, 0)

        if T.usingSyntheticCorpus {
            // The census the synthetic corpus reproduces, measured over its 43
            // files. These count FILES, not occurrences within them.
            T.eq("B-03  CRLF detected            (census: 8)", crlf, 8)
            T.eq("B-04  missing final newline    (census: 15)", noFinalNL, 15)
            T.eq("B-05  BOM                      (census: 0)", bom, 0)
            T.eq("B-09  lone CR                  (census: 0)", loneCR, 0)
            T.eq("B-10  leading tabs             (census: 0)", leadingTab, 0)
            T.eq("B-11  trailing whitespace      (census: 11)", trailingWS, 11)

            // Astral characters are why every offset in this codebase is a
            // UTF-16 code unit: Swift.String's grapheme indexing disagrees with
            // UTF-16 offsets exactly here. DeadPathTests T-08 rides on these.
            T.eq("B-13  files carrying astral (4-byte UTF-8) characters", astral, 5)
            T.ok("B-14  one file is large enough to be a performance fixture",
                 T.fixture.contains { T.read($0).split(separator: "\n", omittingEmptySubsequences: false).count > 1400 })

            // 39.5% of the corpus shares a basename with another file, which is
            // what makes the rail's disambiguation worth having at all.
            var byName: [String: Int] = [:]
            for p in T.fixture { byName[(p as NSString).lastPathComponent, default: 0] += 1 }
            let shared = T.fixture.filter { byName[($0 as NSString).lastPathComponent]! > 1 }.count
            T.eq("B-15  files sharing a basename with another", shared, 17)
            T.eq("B-16  and SKILL.md is the most-repeated name", byName["SKILL.md"] ?? 0, 6)
        } else {
            print("  ..   B-03..B-16 skipped: CROOK_CORPUS names a different corpus")
        }

        // An offset-sensitive edit is what a no-op round trip cannot exercise.
        let crlfSrc = Data("a\r\nb\r\nc\r\n".utf8)
        if let (t, prof) = try? ByteCodec.decode(crlfSrc) {
            T.eq("B-06  CRLF normalises to LF in the buffer", t as String, "a\nb\nc\n")
            T.eq("B-07  buffer length is LF-counted", t.length, 6)
            t.replaceCharacters(in: NSRange(location: 2, length: 0), with: "X")
            T.eq("B-08  an insert at an LF offset lands correctly",
                 String(data: try! ByteCodec.encode(t, profile: prof), encoding: .utf8)!, "a\r\nXb\r\nc\r\n")
        } else { T.ok("B-06..08 CRLF fixture decodes", false) }
    }
}
