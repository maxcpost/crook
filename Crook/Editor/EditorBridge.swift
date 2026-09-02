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

    func markClean() { dirty = false; onDirty?(false) }

    func pushChangedLines(_ lines: [Int]) {
        guard isReady, let wv = webView else { return }
        wv.callAsyncJavaScript("CrookEditor.applyChangedLines(l);",
                               arguments: ["l": lines], in: nil, in: .page) { _ in }
    }

    /// Push dead-path verdicts to the editor. Swift owns the filesystem, so
    /// this cannot be computed in the web view. Draw nothing when the scan
    /// finds nothing — a clean file renders zero extra pixels.
    func pushDiagnostics(for url: URL?) {
        guard isReady, let wv = webView else { return }
        let dead = PathScanner.scan(text as String, url: url)
        let payload: [[String: Any]] = dead.map { d in
            // The teaching half. "Broken" is a dead end; "exists up to
            // /Users" says a home directory was renamed and absolute paths do
            // not follow — which generalises to the other sixteen.
            let where_ = d.existsUpTo.map { "Exists up to \($0)" } ?? "No part of this path exists"
            return ["from": d.from, "to": d.to, "title": "Not on this machine · \(where_)"]
        }
        wv.callAsyncJavaScript("CrookEditor.applyDiagnostics(d);",
                               arguments: ["d": payload], in: nil, in: .page) { _ in }
        lastDead = dead
    }

    private(set) var lastDead: [PathScanner.DeadPath] = []

    // MARK: - crash recovery

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Crook: web content process terminated — reloading and reseeding")
        isReady = false
        webView.reload()
    }
}
