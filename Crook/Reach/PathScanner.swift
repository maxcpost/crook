import Foundation

/// Finds absolute paths in a document that no longer exist.
///
/// This is a real and silent failure mode. On the machine this was written
/// on, half the slash commands named paths under a home directory that had
/// since been renamed. Nothing reported it. Each file looked completely fine
/// and did nothing.
///
/// Seven stages. Each stage's only two outcomes are NARROW THE CANDIDATE and
/// DISCARD IT ENTIRELY. No stage widens a candidate, which is the structural
/// reason this cannot invent an underline.
///
/// All offsets are UTF-16 code units into the canonical LF-only buffer — the
/// same coordinate space as NSMutableString.length, the bridge's iterChanges
/// triples, and CM6's doc.length. That holds through the 9 astral-character
/// files where Swift.String's grapheme indexing would not.
enum PathScanner {

    struct DeadPath {
        let from: Int          // UTF-16 offset
        let to: Int
        let path: String
        /// The deepest ancestor that does exist — where the path stops being real.
        let existsUpTo: String?
    }

    /// Characters that may appear inside a path run. ASCII only, deliberately:
    /// a non-ASCII unit ends the run and stage 4 then discards the candidate
    /// rather than underlining a truncation of it.
    private static let charset: Set<UInt16> = {
        var s = Set<UInt16>()
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+@#%&=,'()~/" {
            s.insert(c.utf16.first!)
        }
        return s
    }()

    /// A run that stops early at one of these means the reference continues in
    /// a form we cannot resolve. Discard whole — never truncate, never report.
    private static let continuationGuard: Set<UInt16> = {
        Set("*?[]${}<>!|".unicodeScalars.map { UInt16($0.value) })
    }()

    /// Characters that may not immediately precede an anchor.
    private static let anchorLookbehindBlock: Set<UInt16> = {
        var s = Set<UInt16>()
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.~/-" {
            s.insert(c.utf16.first!)
        }
        return s
    }()

    private static let SLASH: UInt16 = 0x2F
    private static let SPACE: UInt16 = 0x20
    private static let NEWLINE: UInt16 = 0x0A
    private static let BACKTICK: UInt16 = 0x60
    private static let TILDE: UInt16 = 0x7E
    private static let DASH: UInt16 = 0x2D

    // MARK: - entry point

    /// - Parameter roleGated: only scan files Crook has classified into a
    ///   Claude Code role. A path in a README is prose; a path in a slash
    ///   command is an instruction.
    static func scan(_ text: String, url: URL?, roleGated: Bool = true) -> [DeadPath] {
        if roleGated, let url, !ReachClassifier.hasRole(url) { return [] }

        let u = Array(text.utf16)
        guard !u.isEmpty else { return [] }
        let fenced = fencedRanges(u)
        var out: [DeadPath] = []
        var i = 0

        while i < u.count {
            guard let anchorLen = anchorLength(u, at: i) else { i += 1; continue }
            if fenced.contains(where: { $0.contains(i) }) { i += 1; continue }
            if i > 0, anchorLookbehindBlock.contains(u[i - 1]) { i += 1; continue }

            let (end, stoppedEarly, stopChar) = extent(u, from: i, anchorLen: anchorLen)

            // Stage 4 — the continuation guard.
            if stoppedEarly, let c = stopChar, continuationGuard.contains(c) || c > 0x7F {
                i = end
                continue
            }

            var candidate = String(utf16CodeUnits: Array(u[i..<end]), count: end - i)
            // Trailing punctuation that ends a sentence rather than a path.
            while let last = candidate.last, ".,;:)'".contains(last) {
                candidate.removeLast()
            }

            // Stage 5a — the enclosing code span.
            // A span holding a space OUTSIDE the matched path is a command
            // line, not a reference: `~/venvs/x/bin/pytest tests/ -q`. Spaces
            // INSIDE the match are legitimate — 12 of 22 project paths contain
            // one, all under "Int Projects/".
            if let span = enclosingCodeSpan(u, at: i) {
                var k = span.lowerBound
                var strayspace = false
                while k < span.upperBound {
                    if u[k] == SPACE && !(k >= i && k < end) { strayspace = true; break }
                    k += 1
                }
                if strayspace { i = end; continue }
            }

            // Stage 5 — disqualifiers.
            // An elided segment is a template, not a reference:
            // `~/.claude/.../memory/`. It cannot exist and was never meant to.
            if candidate.split(separator: "/").contains(where: { seg in
                seg.count >= 2 && seg.allSatisfy { $0 == "." }
            }) { i = end; continue }

            let expanded = candidate.hasPrefix("~/")
                ? Paths.home + String(candidate.dropFirst(1))
                : candidate
            let belowRoot = expanded.hasPrefix("/Users/")
                ? expanded.dropFirst("/Users/".count).contains("/")
                : false
            if !belowRoot { i = end; continue }

            // Stage 6 — does it exist?
            if !FileManager.default.fileExists(atPath: expanded) {
                out.append(DeadPath(from: i,
                                    to: i + candidate.utf16.count,
                                    path: candidate,
                                    existsUpTo: deepestExisting(expanded)))
            }
            i = end
        }
        return out
    }

    // MARK: - stages

    private static func anchorLength(_ u: [UInt16], at i: Int) -> Int? {
        // "~/"
        if u[i] == TILDE, i + 1 < u.count, u[i + 1] == SLASH { return 2 }
        // "/Users/"
        let users: [UInt16] = Array("/Users/".utf16)
        guard i + users.count <= u.count else { return nil }
        for (k, c) in users.enumerated() where u[i + k] != c { return nil }
        return users.count
    }

    /// Stage 3 — extent, including the space rule.
    private static func extent(_ u: [UInt16], from start: Int, anchorLen: Int) -> (Int, Bool, UInt16?) {
        var j = start + anchorLen
        while j < u.count {
            let c = u[j]
            if c == NEWLINE || c == BACKTICK { return (j, false, nil) }
            if c == SPACE {
                if spaceJoins(u, at: j) { j += 1; continue }
                return (j, false, nil)
            }
            if charset.contains(c) {
                // A second anchor terminates the run rather than extending it.
                if j > start + anchorLen, anchorLength(u, at: j) != nil, !anchorLookbehindBlock.contains(u[j - 1]) {
                    return (j, false, nil)
                }
                j += 1
                continue
            }
            return (j, true, c)   // stopped early
        }
        return (u.count, false, nil)
    }

    /// A space joins the run iff all five hold. Each rule kills a real case
    /// measured in the corpus; 12 of 22 project paths contain a space, all
    /// under "Int Projects/".
    private static func spaceJoins(_ u: [UInt16], at p: Int) -> Bool {
        // R1 — the next character is a single charset character, not a space.
        guard p + 1 < u.count, charset.contains(u[p + 1]) else { return false }
        // R2 — and it is not a dash. Kills "pytest tests/ -q".
        guard u[p + 1] != DASH else { return false }
        // R3 — a "/" occurs later in the run, after p.
        // R4 — and the run does not reach a second anchor before that "/".
        var k = p + 1
        while k < u.count {
            let c = u[k]
            if c == NEWLINE || c == BACKTICK { return false }
            if c == SLASH { break }
            if anchorLength(u, at: k) != nil { return false }   // R4
            if c != SPACE && !charset.contains(c) { return false }
            k += 1
        }
        guard k < u.count, u[k] == SLASH else { return false }  // R3
        // R5 — the segment ending at p is not a filename with an extension.
        var segStart = p
        while segStart > 0, u[segStart - 1] != SLASH, u[segStart - 1] != SPACE { segStart -= 1 }
        let seg = String(utf16CodeUnits: Array(u[segStart..<p]), count: p - segStart)
        if let dot = seg.lastIndex(of: ".") {
            let ext = seg[seg.index(after: dot)...]
            if !ext.isEmpty, ext.count <= 8, ext.first!.isLetter,
               ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return false }
        }
        return true
    }

    /// The inline code span containing an offset, if any. Backtick runs must
    /// match in length, per CommonMark.
    private static func enclosingCodeSpan(_ u: [UInt16], at idx: Int) -> Range<Int>? {
        // Scan the line for backtick runs and pair them.
        var lineStart = idx
        while lineStart > 0, u[lineStart - 1] != NEWLINE { lineStart -= 1 }
        var lineEnd = idx
        while lineEnd < u.count, u[lineEnd] != NEWLINE { lineEnd += 1 }

        var k = lineStart
        var openStart = -1, openLen = 0
        while k < lineEnd {
            if u[k] == BACKTICK {
                var run = 0
                while k + run < lineEnd, u[k + run] == BACKTICK { run += 1 }
                if openStart < 0 {
                    openStart = k + run; openLen = run
                } else if run == openLen {
                    if idx >= openStart && idx < k { return openStart..<k }
                    openStart = -1; openLen = 0
                }
                k += run
                continue
            }
            k += 1
        }
        return nil
    }

    /// Stage 2 — CommonMark fenced code blocks.
    private static func fencedRanges(_ u: [UInt16]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        var openAt: Int?
        var openChar: UInt16 = 0
        var openLen = 0

        while i < u.count {
            var lineEnd = i
            while lineEnd < u.count, u[lineEnd] != NEWLINE { lineEnd += 1 }

            var k = i
            var indent = 0
            while k < lineEnd, u[k] == SPACE, indent < 4 { k += 1; indent += 1 }
            if indent <= 3, k < lineEnd, u[k] == BACKTICK || u[k] == 0x7E {
                let ch = u[k]
                var run = 0
                while k + run < lineEnd, u[k + run] == ch { run += 1 }
                if run >= 3 {
                    if let s = openAt {
                        if ch == openChar && run >= openLen {
                            out.append(s..<min(lineEnd + 1, u.count))
                            openAt = nil
                        }
                    } else {
                        // A backtick fence whose info string contains a backtick is not a fence.
                        var infoHasBacktick = false
                        if ch == BACKTICK {
                            var m = k + run
                            while m < lineEnd { if u[m] == BACKTICK { infoHasBacktick = true; break }; m += 1 }
                        }
                        if !infoHasBacktick { openAt = i; openChar = ch; openLen = run }
                    }
                }
            }
            i = lineEnd + 1
        }
        if let s = openAt { out.append(s..<u.count) }   // unclosed runs to EOF
        return out
    }

    /// Where the path stops being real. This is the teaching half: "broken" is
    /// a dead end, while "broken below /Users/<olduser>" says a home directory
    /// was renamed and absolute paths do not follow.
    private static func deepestExisting(_ path: String) -> String? {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        var hops = 0
        while hops < 24, url.path.count > 1 {
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
            url = url.deletingLastPathComponent()
            hops += 1
        }
        return nil
    }
}
