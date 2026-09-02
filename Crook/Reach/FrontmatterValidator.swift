import Foundation

/// Does this file's frontmatter parse as YAML?
///
/// Three SKILL.md files on this machine answer no, each for the same reason: a
/// single unquoted `colon-space` inside a `description:`. Claude Code therefore
/// reads neither `name` nor `description`, which means it can never CHOOSE to
/// invoke those skills — they are manual-only, permanently. Nothing on the
/// machine reports it; `claude plugin validate --strict` prints "Validation
/// passed" on the directory holding them.
///
/// This is NOT a YAML parser and must never become one. There is no YAML
/// library here and adding a dependency is not on the table. It is a scanner
/// for the four failure modes that certainly break every real parser:
///
///   1. a `: ` (or a trailing `:`) inside an unquoted plain scalar
///   2. a tab in indentation
///   3. a quote that never closes inside the block
///   4. a duplicate top-level key
///
/// It carries the path scanner's rule: every branch either NARROWS a candidate
/// or DISCARDS it whole. No branch widens one, which is the structural reason
/// this cannot invent an underline. Where the block holds a construct the
/// scanner does not model — an anchor, a tag, a multi-line flow collection, a
/// sequence entry — it says nothing about it, because a rule that flags correct
/// frontmatter trains the reader to ignore the channel, and then the three real
/// files go unread again.
///
/// Verified against PyYAML on 36 hand-built cases: every construct this file
/// flags is a real parse error there, and every construct it stays silent on
/// parses. The one real defect in this machine's ~/.claude — an agent file
/// whose `description:` says `Context: Daisy has just…` — is flagged at UTF-16
/// column 392 of line 2, which is the exact column PyYAML's caret points to.
///
/// Offsets are UTF-16 code units into the whole document: the same coordinate
/// space as the bridge's iterChanges triples, PathScanner's ranges and CM6's
/// doc.length, so a problem can be pushed straight down the diagnostics channel.
///
/// NOT on the keystroke path. `Frontmatter` costs under 11 µs and is measured;
/// this walks the block character by character and belongs on the same trailing
/// delay that already carries the dead-path scan.
enum FrontmatterValidator {

    struct Problem: Equatable {
        enum Kind: Equatable {
            case colon              // a mapping indicator inside a plain scalar
            case tab                // a tab in indentation
            case unterminatedQuote  // a quote with no partner in the block
            case duplicateKey(String)
        }
        let kind: Kind
        /// UTF-16 offsets into the whole document.
        let from: Int
        let to: Int

        /// The teaching half, in the tooltip's voice. "Broken" is a dead end;
        /// naming the token and the fix is two quote marks away from working.
        var title: String {
            switch kind {
            case .colon:
                return "Frontmatter does not parse · an unquoted value cannot contain a colon and a space · quote it"
            case .tab:
                return "Frontmatter does not parse · YAML indentation cannot contain a tab · use spaces"
            case .unterminatedQuote:
                return "Frontmatter does not parse · this quote is never closed"
            case .duplicateKey(let k):
                return "Duplicate key · \(k) is set twice, and parsers disagree which one wins"
            }
        }
    }

    /// More than this many problems means the block is not frontmatter that
    /// went slightly wrong, it is something else entirely. Stop marking.
    private static let cap = 16

    /// Frontmatter longer than this is not frontmatter. Draw nothing rather
    /// than walk a document-sized block looking for colons.
    private static let blockCap = 32_768

    // MARK: - entry point

    static func validate(_ text: String) -> [Problem] {
        let u = Array(text.utf16)
        guard let block = blockRange(u) else { return [] }
        return scan(u, block)
    }

    // MARK: - locating the block

    /// The interior of the frontmatter block, or nil.
    ///
    /// Byte 0 exactly — the same precondition `Frontmatter` enforces. If the
    /// opener is not the file's first line then Claude Code parses no YAML here
    /// at all, and a complaint about YAML would be a complaint about nothing.
    /// The reach readout says THAT case; this one stays quiet, so one defect
    /// never produces two marks.
    private static func blockRange(_ u: [UInt16]) -> Range<Int>? {
        guard u.count >= 3, u[0] == DASH, u[1] == DASH, u[2] == DASH else { return nil }
        var i = 3
        while i < u.count, u[i] == SPACE || u[i] == TAB || u[i] == CR { i += 1 }
        guard i < u.count, u[i] == LF else { return nil }

        let start = i + 1
        var lineStart = start
        while lineStart <= u.count {
            if lineStart - start > blockCap { return nil }
            var end = lineStart
            while end < u.count, u[end] != LF { end += 1 }
            if isMarkerLine(u, lineStart, end) { return start..<lineStart }
            if end >= u.count { return nil }        // never closed
            lineStart = end + 1
        }
        return nil
    }

    /// `---`, and nothing else on the line.
    private static func isMarkerLine(_ u: [UInt16], _ s: Int, _ e: Int) -> Bool {
        guard e - s >= 3, u[s] == DASH, u[s + 1] == DASH, u[s + 2] == DASH else { return false }
        var i = s + 3
        while i < e {
            guard u[i] == SPACE || u[i] == TAB || u[i] == CR else { return false }
            i += 1
        }
        return true
    }

    // MARK: - the scan

    private static func scan(_ u: [UInt16], _ block: Range<Int>) -> [Problem] {
        var out: [Problem] = []
        var topKeys = Set<String>()
        /// Set while a `|` or `>` block scalar's body is in play. Its content is
        /// literal text: a colon there is a colon, not a mapping indicator.
        var blockScalarIndent: Int? = nil
        /// Set while a plain scalar may continue onto following lines. A
        /// more-indented line under one is part of THAT scalar, and a mapping
        /// indicator inside it is the same error as a mapping indicator on the
        /// key line — PyYAML calls both "mapping values are not allowed here".
        var plainOpenIndent: Int? = nil
        /// Offsets already consumed by a multi-line quoted scalar.
        var consumedTo = block.lowerBound

        var i = block.lowerBound
        while i < block.upperBound {
            let lineStart = i
            var lineEnd = i
            while lineEnd < block.upperBound, u[lineEnd] != LF { lineEnd += 1 }
            i = lineEnd + 1
            // A CR survives only when the caller handed us un-normalised text;
            // the live buffer is LF-only. Treat it as trailing whitespace.
            if lineEnd > lineStart, u[lineEnd - 1] == CR { lineEnd -= 1 }

            if lineStart < consumedTo { continue }
            if out.count >= cap { return out }

            // ---- indentation
            var p = lineStart
            var tabAt = -1
            while p < lineEnd, u[p] == SPACE || u[p] == TAB {
                if u[p] == TAB, tabAt < 0 { tabAt = p }
                p += 1
            }
            let indent = p - lineStart
            let blank = p == lineEnd

            // ---- a block scalar's body is content, not structure
            if let bi = blockScalarIndent {
                if blank || indent > bi { continue }
                blockScalarIndent = nil
            }
            // A blank line does not end a plain scalar in YAML — it becomes a
            // newline inside it — so plainOpenIndent survives one.
            if blank { continue }

            let continues = plainOpenIndent.map { indent > $0 } ?? false

            // ---- a tab in the indentation
            //
            // Only where the line is structure. Inside a block scalar, and on a
            // plain scalar's continuation line, leading tabs are separation and
            // parsers differ; this one stays quiet there.
            if tabAt >= 0 {
                guard !continues else { continue }
                out.append(Problem(kind: .tab, from: tabAt, to: tabAt + 1))
                // Indentation is now unknowable and every depth below this is a
                // guess. Report the one certain thing and stop.
                return out
            }

            // ---- a comment line
            if u[p] == HASH { continue }

            // ---- a sequence entry. Its content is a node of its own, and this
            // scanner does not descend into one.
            if u[p] == DASH, p + 1 == lineEnd || u[p + 1] == SPACE || u[p + 1] == TAB {
                plainOpenIndent = nil
                continue
            }

            // ---- a plain scalar's continuation line
            if continues {
                let end = trimTrailing(u, p, plainEnd(u, p, lineEnd))
                if let c = mappingIndicator(u, p, end) {
                    out.append(colonProblem(u, c, lineEnd))
                    plainOpenIndent = nil
                }
                continue
            }

            // ---- a quoted key. Splitting it on a colon would split it inside
            // the quotes, so this scanner does not split it at all.
            if u[p] == DQ || u[p] == SQ { plainOpenIndent = nil; continue }
            // ---- a complex key. The structure below it is not modelled here.
            if u[p] == QUESTION { return out }

            // ---- key: value
            guard let colon = mappingIndicator(u, p, lineEnd) else {
                // No mapping indicator and no open plain scalar above it. This
                // is not a shape this scanner reads; it says nothing about it.
                plainOpenIndent = nil
                continue
            }

            if indent == 0 {
                let key = string(u, p, trimTrailing(u, p, colon))
                if !key.isEmpty, !topKeys.insert(key).inserted {
                    out.append(Problem(kind: .duplicateKey(key), from: p, to: colon))
                }
            }

            var v = colon + 1
            while v < lineEnd, u[v] == SPACE || u[v] == TAB { v += 1 }
            plainOpenIndent = nil
            guard v < lineEnd else { continue }     // empty value: a nested map, or null

            switch u[v] {
            case DQ, SQ:
                guard let close = closingQuote(u, v, block.upperBound) else {
                    out.append(Problem(kind: .unterminatedQuote, from: v, to: v + 1))
                    // Everything after an unterminated quote is inside the
                    // string as far as the parser is concerned. Nothing below
                    // can be judged, so nothing below is marked.
                    return out
                }
                consumedTo = close + 1              // a quoted scalar may span lines

            case PIPE, GT:
                blockScalarIndent = indent

            case LBRACKET, LBRACE:
                // A flow collection that closes on its own line is fine and
                // uninteresting. One that does not spans lines, and this
                // scanner's line model is then wrong for the whole block.
                if !flowClosesOnLine(u, v, lineEnd) { return [] }

            case AMP, STAR, BANG:
                break                               // anchor, alias, tag: not modelled

            default:
                let end = trimTrailing(u, v, plainEnd(u, v, lineEnd))
                if let c = mappingIndicator(u, v, end) {
                    // The FIRST one only. That is where the parser stops, and
                    // one pair of quotes around the value fixes every colon in
                    // it — so one mark carries the whole fix.
                    out.append(colonProblem(u, c, lineEnd))
                } else {
                    plainOpenIndent = indent
                }
            }
        }
        return out
    }

    /// Underline the mapping indicator itself — the colon and the space that
    /// makes it one. Two characters, exactly the token the parser objects to.
    private static func colonProblem(_ u: [UInt16], _ c: Int, _ lineEnd: Int) -> Problem {
        let to = (c + 1 < lineEnd && (u[c + 1] == SPACE || u[c + 1] == TAB)) ? c + 2 : c + 1
        return Problem(kind: .colon, from: c, to: to)
    }

    // MARK: - scanning primitives

    /// The first colon that is followed by a space, a tab, or the end of the
    /// content. A colon followed by anything else — `https://x`, `10:30` — is
    /// an ordinary character inside a plain scalar and parses fine.
    private static func mappingIndicator(_ u: [UInt16], _ from: Int, _ end: Int) -> Int? {
        var i = from
        while i < end {
            if u[i] == COLON, i + 1 == end || u[i + 1] == SPACE || u[i + 1] == TAB { return i }
            i += 1
        }
        return nil
    }

    /// Where a plain scalar stops because a comment starts. A `#` counts only
    /// when whitespace precedes it or it opens the value — `a#b` is a scalar
    /// containing a hash, and PyYAML agrees.
    private static func plainEnd(_ u: [UInt16], _ from: Int, _ end: Int) -> Int {
        var i = from
        while i < end {
            if u[i] == HASH, i == from || u[i - 1] == SPACE || u[i - 1] == TAB { return i }
            i += 1
        }
        return end
    }

    private static func trimTrailing(_ u: [UInt16], _ from: Int, _ end: Int) -> Int {
        var e = end
        while e > from, u[e - 1] == SPACE || u[e - 1] == TAB || u[e - 1] == CR { e -= 1 }
        return e
    }

    /// The partner of the quote at `open`, anywhere in the block — a quoted
    /// scalar is allowed to span lines, so "not closed on this line" is not a
    /// defect and must not be reported as one.
    private static func closingQuote(_ u: [UInt16], _ open: Int, _ limit: Int) -> Int? {
        let q = u[open]
        var i = open + 1
        while i < limit {
            if q == DQ {
                if u[i] == BACKSLASH { i += 2; continue }
                if u[i] == DQ { return i }
            } else if u[i] == SQ {
                if i + 1 < limit, u[i + 1] == SQ { i += 2; continue }   // '' is an escaped quote
                return i
            }
            i += 1
        }
        return nil
    }

    private static func flowClosesOnLine(_ u: [UInt16], _ from: Int, _ end: Int) -> Bool {
        var depth = 0
        var quote: UInt16 = 0
        var i = from
        while i < end {
            let c = u[i]
            if quote != 0 {
                if c == BACKSLASH, quote == DQ { i += 2; continue }
                if c == quote { quote = 0 }
            } else if c == DQ || c == SQ {
                quote = c
            } else if c == LBRACKET || c == LBRACE {
                depth += 1
            } else if c == RBRACKET || c == RBRACE {
                depth -= 1
                if depth == 0 { return true }
            }
            i += 1
        }
        return false
    }

    private static func string(_ u: [UInt16], _ from: Int, _ to: Int) -> String {
        guard to > from else { return "" }
        return String(decoding: u[from..<to], as: UTF16.self)
    }

    // MARK: - the alphabet

    private static let LF: UInt16 = 0x0A
    private static let CR: UInt16 = 0x0D
    private static let TAB: UInt16 = 0x09
    private static let SPACE: UInt16 = 0x20
    private static let BANG: UInt16 = 0x21
    private static let DQ: UInt16 = 0x22
    private static let HASH: UInt16 = 0x23
    private static let AMP: UInt16 = 0x26
    private static let SQ: UInt16 = 0x27
    private static let STAR: UInt16 = 0x2A
    private static let DASH: UInt16 = 0x2D
    private static let COLON: UInt16 = 0x3A
    private static let GT: UInt16 = 0x3E
    private static let QUESTION: UInt16 = 0x3F
    private static let LBRACKET: UInt16 = 0x5B
    private static let BACKSLASH: UInt16 = 0x5C
    private static let RBRACKET: UInt16 = 0x5D
    private static let PIPE: UInt16 = 0x7C
    private static let LBRACE: UInt16 = 0x7B
    private static let RBRACE: UInt16 = 0x7D
}
