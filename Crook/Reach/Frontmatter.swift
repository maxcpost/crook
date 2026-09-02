import Foundation

/// A deliberately small frontmatter reader.
///
/// This is NOT a YAML parser and must never become one. It answers three
/// questions the classifier asks — is there frontmatter at all, what is the
/// scalar value of a top-level key, and is a key present — from the live buffer,
/// on every keystroke. Anything richer belongs to the validation layer.
///
/// Claude Code reads frontmatter only when the opening `---` is the file's very
/// first line; otherwise the whole file, markers included, is content. That is
/// one byte-0 comparison and it is the precondition for everything below.
struct Frontmatter {

    /// The one cap, used at BOTH sites: the frontmatter scan here and the
    /// edit-offset gate that decides whether to recompute at all. Two different
    /// numbers would be indistinguishable on this corpus — the longest
    /// frontmatter measures 1,187 characters and none of 193 exceeds 2,048 —
    /// which is exactly how they would silently drift apart.
    static let scanLimit = 2048

    /// Nil when the file has no frontmatter Claude Code would read.
    private var bodyStore: String? = nil
    var body: Substring? { bodyStore.map { $0[...] } }
    /// True when a `---` block exists but not at byte 0 — the silent case.
    let misplaced: Bool
    /// Top-level scalars, parsed once. Every lookup after that is a dictionary
    /// hit rather than a re-split of the block.
    private let scalars: [String: String]

    init(_ text: String) {
        // Work on the UTF-8 view, not on Characters. Character-based
        // index(offsetBy:) alone measured 4.5 µs on a 3 KB document, and the
        // whole type measured 20.6 — this is the entire cost of the keystroke
        // path, so it is worth the byte arithmetic.
        // Walk the view; do not materialise it. Array(text.utf8.prefix(2048))
        // memcpy'd 2 KB on every keystroke for a frontmatter block that is
        // typically under 500 bytes.
        let DASH: UInt8 = 0x2D, LF: UInt8 = 0x0A, CR: UInt8 = 0x0D
        var u = [UInt8]()
        u.reserveCapacity(512)
        var run = 0                      // trailing "\n---" match length
        var closeAt = -1
        for b in text.utf8 {
            if u.count >= Self.scanLimit { break }
            u.append(b)
            if u.count > 3 {
                switch (run, b) {
                case (0, LF): run = 1
                case (1, DASH), (2, DASH): run += 1
                case (3, DASH): closeAt = u.count - 4
                default: run = (b == LF) ? 1 : 0
                }
                if closeAt >= 0 { break }
            }
        }

        // Byte 0 exactly. Claude Code reads frontmatter only when the opening
        // `---` is the file's first line; otherwise the whole file, markers
        // included, is content.
        guard u.count >= 3, u[0] == DASH, u[1] == DASH, u[2] == DASH,
              u.count == 3 || u[3] == LF || u[3] == CR else {
            self.bodyStore = nil
            self.scalars = [:]
            // A `---` block that exists but is not at byte 0: the silent case.
            self.misplaced = Self.hasDisplacedBlock(u)
            return
        }

        let close = closeAt
        guard close >= 0 else {
            // Unterminated within the cap: Claude Code sees no frontmatter.
            self.bodyStore = nil
            self.misplaced = false
            self.scalars = [:]
            return
        }

        let raw = String(decoding: u[3..<close], as: UTF8.self)
        self.bodyStore = raw
        self.misplaced = false

        // Top-level scalars, parsed once. Every lookup after that is a
        // dictionary hit rather than a re-split of the block.
        var map: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let f = line.first, !f.isWhitespace,
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if map[key] == nil { map[key] = v }
        }
        self.scalars = map
    }

    var exists: Bool { body != nil }

    // MARK: - the silent case

    /// Frontmatter that Claude Code will not read because something precedes
    /// the opening `---`: a blank line, a stray space, a BOM. The whole file,
    /// markers included, is then content, and every field below is ignored.
    ///
    /// The rule is deliberately narrow: ONLY whitespace or a BOM may precede
    /// the opener, the block must close, and it must contain at least one
    /// `key:` line. An earlier version asked only whether `\n---\n` appeared
    /// anywhere in the first 2 KB, which is true of a setext heading and of
    /// every markdown horizontal rule — it fired on 237 of this machine's
    /// 1,551 markdown files, essentially none of them defective. That flag was
    /// read by nothing, so it cost nothing; the moment it reaches the readout
    /// it has to be right, and a rule that is wrong 237 times teaches the
    /// reader to stop reading the readout.
    private static func hasDisplacedBlock(_ u: [UInt8]) -> Bool {
        let DASH: UInt8 = 0x2D, LF: UInt8 = 0x0A, CR: UInt8 = 0x0D
        let SPACE: UInt8 = 0x20, TAB: UInt8 = 0x09

        var i = 0
        // A UTF-8 BOM. Invisible in every editor on the machine, and on its own
        // enough to make the frontmatter unreadable.
        if u.count >= 3, u[0] == 0xEF, u[1] == 0xBB, u[2] == 0xBF { i = 3 }
        var displaced = i > 0
        while i < u.count, u[i] == SPACE || u[i] == TAB || u[i] == LF || u[i] == CR {
            i += 1
            displaced = true
        }
        // Nothing was in the way: this is either real frontmatter, handled by
        // the caller, or a file with none.
        guard displaced else { return false }

        // The opener, alone on its line.
        guard i + 2 < u.count, u[i] == DASH, u[i + 1] == DASH, u[i + 2] == DASH else { return false }
        var j = i + 3
        while j < u.count, u[j] == SPACE || u[j] == TAB || u[j] == CR { j += 1 }
        guard j < u.count, u[j] == LF else { return false }

        // A closing marker, and at least one key before it. Without the key
        // requirement a pair of horizontal rules under a blank first line
        // reads as frontmatter, which it never is.
        var lineStart = j + 1
        var sawKey = false
        while lineStart <= u.count {
            var end = lineStart
            while end < u.count, u[end] != LF { end += 1 }
            if isCloser(u, lineStart, end) { return sawKey }
            if !sawKey, hasKey(u, lineStart, end) { sawKey = true }
            if end >= u.count { return false }
            lineStart = end + 1
        }
        return false
    }

    /// `---`, and nothing else on the line.
    private static func isCloser(_ u: [UInt8], _ s: Int, _ e: Int) -> Bool {
        guard e - s >= 3, u[s] == 0x2D, u[s + 1] == 0x2D, u[s + 2] == 0x2D else { return false }
        var i = s + 3
        while i < e {
            guard u[i] == 0x20 || u[i] == 0x09 || u[i] == 0x0D else { return false }
            i += 1
        }
        return true
    }

    /// A plausible top-level scalar key: `name:`, `description:`, `allowed-tools:`.
    private static func hasKey(_ u: [UInt8], _ s: Int, _ e: Int) -> Bool {
        var i = s
        while i < e {
            let c = u[i]
            let letter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            let digit = c >= 0x30 && c <= 0x39
            let joiner = c == 0x5F || c == 0x2D || c == 0x2E     // _ - .
            if i == s { guard letter || c == 0x5F else { return false } }
            else if c == 0x3A { return true }                    // :
            else if !(letter || digit || joiner) { return false }
            i += 1
        }
        return false
    }

    /// The scalar value of a top-level key, unquoted and trimmed.
    /// Returns nil for an absent key, and "" for a key with an empty value.
    /// Nested keys are invisible here by design — `metadata:` children are not
    /// top-level and Claude Code does not read them as such.
    func value(_ key: String) -> String? { scalars[key] }

    func flagIsTrue(_ key: String) -> Bool { value(key)?.lowercased() == "true" }
    func flagIsFalse(_ key: String) -> Bool { value(key)?.lowercased() == "false" }

    /// The first entry of a block or flow sequence under `key`, if it is a
    /// plain scalar. Used only for `paths:` — a pattern Crook can quote back.
    func firstSequenceEntry(_ key: String) -> String? {
        guard let body else { return nil }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let i = lines.firstIndex(where: { l in
            guard let f = l.first, !f.isWhitespace else { return false }
            return l.hasPrefix(key) && l.dropFirst(key.count).hasPrefix(":")
        }) else { return nil }

        // Flow form: paths: ["a", "b"]
        let inline = lines[i].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if inline.hasPrefix("[") {
            let inner = inline.dropFirst().prefix(while: { $0 != "]" })
            let first = inner.split(separator: ",").first?
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (first?.isEmpty ?? true) ? nil : first
        }
        if !inline.isEmpty { return inline }

        // Block form: the next indented "- entry"
        var j = lines.index(after: i)
        while j < lines.endIndex {
            let l = lines[j]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { j = lines.index(after: j); continue }
            guard let f = l.first, f.isWhitespace, t.hasPrefix("- ") else { return nil }
            let v = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return v.isEmpty ? nil : v
        }
        return nil
    }
}
