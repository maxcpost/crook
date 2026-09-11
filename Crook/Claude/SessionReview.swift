import Foundation

/// The arithmetic of reviewing a session: which lines to highlight, how much
/// changed, and putting bytes back.
enum SessionReview {

    /// Lines in `after` that are new since `before`, 1-based: every added line,
    /// and for a pure removal the line now sitting where it was.
    ///
    /// Precise rather than LineDiff's first-to-last span, which is the right
    /// call for a single agent rewrite and the wrong one for a rename: two
    /// touched lines seventy apart would light up seventy-eight.
    static func changedLines(before: String, after: String) -> [Int] {
        guard before != after else { return [] }
        let (lines, _) = UnifiedDiff.between(before, after, context: 1)
        let total = after.components(separatedBy: "\n").count
        var out = Set<Int>()
        var removalPending = false
        for line in lines {
            switch line.kind {
            case .added:
                if let n = line.newNo { out.insert(n) }
                removalPending = false
            case .removed:
                removalPending = true
            case .context:
                if removalPending, let n = line.newNo { out.insert(n) }
                removalPending = false
            case .gap:
                break
            }
        }
        if removalPending { out.insert(max(1, total)) }
        return out.sorted()
    }

    static func tally(baseline: String, current: String) -> (added: Int, removed: Int) {
        guard baseline != current else { return (0, 0) }
        let summary = UnifiedDiff.between(baseline, current).1
        return (summary.added, summary.removed)
    }

    /// Replace a file's bytes only if they are still exactly `expecting`.
    ///
    /// Undo and Redo each promise to replace one specific version. Anything
    /// else on disk — the person's own edit, another agent's — is left alone,
    /// and false says nothing was written.
    static func replace(path: String, on provider: FileProvider, expecting: Data, with bytes: Data) throws -> Bool {
        guard provider.contents(path) == expecting else { return false }
        try provider.write(bytes, to: path)
        return true
    }

    /// The folder macOS guards behind a privacy grant, by the name System
    /// Settings uses for it.
    static func protectedFolder(for path: String, home: String) -> String? {
        for name in ["Desktop", "Documents", "Downloads"] {
            let root = home + "/" + name
            if path == root || path.hasPrefix(root + "/") { return name }
        }
        return nil
    }
}
