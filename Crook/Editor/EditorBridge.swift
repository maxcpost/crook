import AppKit
import WebKit

/// The Swift↔CodeMirror bridge. Swift owns the canonical text; CodeMirror is the
/// view. JS→Swift is fire-and-forget over one message handler carrying
/// iterChanges triples. Swift→JS uses callAsyncJavaScript with an arguments
/// dictionary, never string interpolation (S03).
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    /// The canonical buffer. NSMutableString / UTF-16 throughout: 228 of the 270
    /// fixture files are non-ASCII and 9 contain astral characters, where
    /// Swift.String's grapheme indexing disagrees with CM6's UTF-16 offsets.
    private(set) var text = NSMutableString()
    private(set) var profile = ByteProfile(lineEnding: .lf, hasFinalNewline: true,
                                           bom: nil, encoding: .utf8, mixedLineEndings: false)
    private(set) var generation = 0
    private(set) var isReady = false
    private(set) var caret = 0

    var onDirty: ((Bool) -> Void)?
    /// Fires after every applied edit batch with the lowest offset touched.
    /// Reached By uses it to recompute only when the frontmatter region moved.
    var onEdit: ((Int) -> Void)?
    /// The reader moved the caret — they are looking at this document.
    var onEngage: (() -> Void)?
    var onReady: (() -> Void)?
    /// The reader tried to type while an Edit with Claude session has the file.
    var onReadOnlyAttempt: (() -> Void)?
    private var readOnly = false

    weak var webView: WKWebView?
    private var seenSeq = 0
    private var dirty = false

    func load(text newText: NSMutableString, profile newProfile: ByteProfile) {
        text = newText
        profile = newProfile
        generation += 1
        dirty = false
        pushDocument()
    }

    private func pushDocument() {
        guard isReady, let wv = webView else { return }
        // setDocument is the ONE sanctioned full-text push: initial load and
        // post-crash reseed only (S03 §6).
        wv.callAsyncJavaScript(
            "CrookEditor.setDocument(t, g, c, null);",
            arguments: ["t": text as String, "g": generation, "c": caret],
            in: nil, in: .page) { _ in }
    }

    // MARK: - JS → Swift

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "editorReady":
            isReady = true
            pushDocument()
            // A web content process that crashed and reloaded mid-session
            // must come back read-only, not quietly editable.
            pushReadOnly()
            onReady?()
            // Self-check: confirm CM6's doc length equals the canonical buffer's
            // UTF-16 length. They must agree or every offset is wrong (S02).
            if ProcessInfo.processInfo.environment["CROOK_SELFTEST_SELECT"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak wv = self.webView] in
                    wv?.evaluateJavaScript("CrookEditor.selectRange(60, 190); 1") { _, _ in }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let wv = self.webView else { return }
                wv.evaluateJavaScript("CrookEditor.getLength()") { v, _ in
                    let js = (v as? Int) ?? -1
                    NSLog("Crook: BRIDGE CHECK swift=\(self.text.length) cm6=\(js) match=\(js == self.text.length)")
                }
            }

        case "edit":
            guard let gen = body["generation"] as? Int, gen == generation,
                  let changes = body["changes"] as? [[Any]] else { return }
            let lowest = applyLocal(changes)
            // Report EVERY edit, not only the false->true transition. Reporting
            // once meant NSDocument stopped being told about changes after the
            // first save, so it believed the document was clean while holding
            // unsaved text — which quit discards without a prompt and an
            // external write overwrites.
            dirty = true
            onDirty?(true)
            if let lowest { onEdit?(lowest) }

        case "selection":
            if let head = body["head"] as? Int { caret = head }
            onEngage?()

        case "readOnlyAttempt":
            onReadOnlyAttempt?()

        case "jserror":
            NSLog("Crook: JS ERROR \(body["message"] ?? "") line \(body["line"] ?? "")")

        case "console":
            NSLog("Crook: JS \(body["message"] ?? "")")

        default:
            NSLog("Crook: unknown message \(type)")
        }
    }

    /// Applies CodeMirror-originated changes to the canonical buffer.
    /// Offsets are UTF-16 code units in an LF-only document on both sides.
    @discardableResult
    private func applyLocal(_ changes: [[Any]]) -> Int? {
        var lowest: Int?
        for c in changes {
            guard c.count == 3,
                  let from = c[0] as? Int,
                  let to = c[1] as? Int,
                  let insert = c[2] as? String else { continue }
            guard from >= 0, to >= from, to <= text.length else {
                NSLog("Crook: bridge offset out of range (\(from)..\(to) of \(text.length)) — dropping")
                continue
            }
            text.replaceCharacters(in: NSRange(location: from, length: to - from), with: insert)
            lowest = min(lowest ?? from, from)
        }
        return lowest
    }

    // MARK: - persistence

    func data() throws -> Data { try ByteCodec.encode(text, profile: profile) }

    /// Drain CodeMirror's per-frame edit batch before a save reads the buffer.
    ///
    /// Edits reach Swift after a requestAnimationFrame plus IPC, so a save
    /// within ~16 ms of a keystroke used to encode text that was missing those
    /// characters. evaluateJavaScript on the main thread with a run-loop spin
    /// is not elegant, but a save is rare, bounded, and must see everything the
    /// user typed. Bounded at 100 ms so a wedged web view cannot hang a save.
    func flushPendingEdits() {
        guard isReady, let wv = webView else { return }
        var done = false
        wv.evaluateJavaScript("CrookEditor.flushNow()") { _, _ in done = true }
        let deadline = Date().addingTimeInterval(0.1)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    func markClean() { dirty = false; onDirty?(false) }

    func pushChangedLines(_ lines: [Int]) {
        guard isReady, let wv = webView else { return }
        wv.callAsyncJavaScript("CrookEditor.applyChangedLines(l);",
                               arguments: ["l": lines], in: nil, in: .page) { _ in }
    }

    /// Refuse input while an Edit with Claude session has the file.
    func setReadOnly(_ on: Bool) {
        guard on != readOnly else { return }
        readOnly = on
        pushReadOnly()
    }

    private func pushReadOnly() {
        guard isReady, let wv = webView else { return }
        wv.callAsyncJavaScript("CrookEditor.setReadOnly(r);", arguments: ["r": readOnly],
                               in: nil, in: .page) { _ in }
    }

    func revealLine(_ line: Int) {
        guard isReady, let wv = webView else { return }
        wv.callAsyncJavaScript("CrookEditor.scrollToLine(n);", arguments: ["n": line],
                               in: nil, in: .page) { _ in }
    }

    /// The current selection as UTF-16 offsets into the canonical buffer.
    func selection(_ done: @escaping (_ anchor: Int, _ head: Int) -> Void) {
        guard isReady, let wv = webView else { done(caret, caret); return }
        wv.evaluateJavaScript("CrookEditor.getSelection()") { [weak self] value, _ in
            let fallback = self?.caret ?? 0
            let d = value as? [String: Any]
            let anchor = d?["anchor"] as? Int ?? fallback
            done(anchor, d?["head"] as? Int ?? anchor)
        }
    }

    /// Push dead-path verdicts and frontmatter defects to the editor. Swift
    /// owns the filesystem, so neither can be computed in the web view. Draw
    /// nothing when both scans find nothing — a clean file renders zero extra
    /// pixels.
    ///
    /// This is also the trailing-delay slot the frontmatter check needs. It
    /// runs on load and 0.6 s after edits settle, never per keystroke, which
    /// keeps `Frontmatter`'s measured sub-11 µs keystroke path untouched.
    func pushDiagnostics(for url: URL?) {
        guard isReady, let wv = webView else { return }
        let doc = text as String
        let dead = PathScanner.scan(doc, url: url)
        var marks: [(from: Int, to: Int, title: String)] = dead.map { d in
            // The teaching half. "Broken" is a dead end; "exists up to
            // /Users" says a home directory was renamed and absolute paths do
            // not follow — which generalises to the other sixteen.
            let where_ = d.existsUpTo.map { "Exists up to \($0)" } ?? "No part of this path exists"
            return (d.from, d.to, "Not on this machine · \(where_)")
        }

        // Frontmatter that does not parse. Only where Claude Code parses it:
        // in a memory file the same `---` block is prose.
        var problems: [FrontmatterValidator.Problem] = []
        if let url, ReachClassifier.parsesFrontmatter(url) {
            problems = FrontmatterValidator.validate(doc)
            marks += problems.map { ($0.from, $0.to, $0.title) }
        }

        // CM6's RangeSetBuilder THROWS on an out-of-order add, and a throw
        // inside applyDiagnostics takes every mark down with it — including
        // the dead paths that were fine. Frontmatter problems sit at the top
        // of the document and dead paths anywhere, so appending them is
        // exactly the out-of-order case. Sort before it leaves Swift.
        marks.sort { ($0.from, $0.to) < ($1.from, $1.to) }
        let payload: [[String: Any]] = marks.map { ["from": $0.from, "to": $0.to, "title": $0.title] }

        wv.callAsyncJavaScript("CrookEditor.applyDiagnostics(d);",
                               arguments: ["d": payload], in: nil, in: .page) { _ in }
        lastDead = dead
        lastProblems = problems
    }

    private(set) var lastDead: [PathScanner.DeadPath] = []
    private(set) var lastProblems: [FrontmatterValidator.Problem] = []

    // MARK: - crash recovery

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Crook: web content process terminated — reloading and reseeding")
        isReady = false
        webView.reload()
    }
}
