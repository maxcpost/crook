import AppKit

/// Who owns a document whose bytes live on another machine.
///
/// A local document is owned by NSDocumentController: openDocument(withContentsOf:)
/// puts it in the `documents` array and that array is what keeps it alive. A
/// remote document cannot go through that call at all — it checks the file
/// exists on THIS machine — so it was built with a bare CrookDocument() and
/// handed straight to install(). Nothing owned it.
///
/// Every reference Crook holds to it is non-owning: `editor.owner` is weak,
/// NSWindowController.document is unowned(unsafe), and addWindowController
/// makes the DOCUMENT retain the controller, not the reverse. What kept one
/// alive at all was whatever AppKit happened to be holding it for — setting
/// fileURL is enough to do that, which is why this was intermittent rather than
/// immediate. A lifetime nobody in this app controls is not a lifetime, and
/// when it ended the window controller was left holding a dangling pointer.
///
/// The crash itself is not in doubt: -[NSDocument addWindowController:] reads
/// that pointer and sends it removeWindowController:. By then the memory had
/// been reused by CoreUI, and the report named _CUIInternalLinkRendition. What
/// was never pinned down is which release finally let go — and it does not
/// change the fix, which is to make the ownership Crook's own rather than
/// AppKit's business. install() also drops the pointer unconditionally now, so
/// a stale one cannot reach AppKit however it got stale.
///
/// The second half is the reason the first half was dangerous to fix. The class
/// comment claims autosave-in-place is disabled for remote documents; no code
/// did that. It never mattered while they lived for a few milliseconds. Give
/// one a real owner and AppKit starts autosaving it — to a local path that is
/// another machine's path.
enum DocumentLifetimeTests {

    private static let remoteURL = URL(fileURLWithPath: "/Users/some-other-mac/.claude/CLAUDE.md")

    static func run() {
        T.suite("documents — owning one that lives on another machine")

        // L-01/L-02: the crash. A document nothing owns is gone by the time
        // install() returns, and everything pointing at it is left dangling.
        weak var escaped: CrookDocument?
        autoreleasepool {
            let doc = try? CrookDocument.makeRemote(
                data: Data("# hello\n".utf8), url: remoteURL, providerID: "ssh:test")
            escaped = doc
            T.ok("L-01  a remote document is built from bytes", doc != nil)
        }
        T.ok("L-02  and outlives the scope that built it", escaped != nil)
        T.ok("L-03  because something actually owns it",
             NSDocumentController.shared.documents.contains { $0 === escaped })

        // L-04: autosave must never write another machine's path onto this
        // disk. The file must not appear, and no directory may be created for
        // it either.
        if let doc = escaped {
            var autosaveError: Error?
            var finished = false
            doc.updateChangeCount(.changeDone)
            doc.autosave(withImplicitCancellability: false) { err in
                autosaveError = err
                finished = true
            }
            // AppKit delivers this on the main queue. Blocking the main thread
            // on a semaphore would deadlock against the very callback it waits
            // for, so turn the run loop instead.
            let deadline = Date().addingTimeInterval(5)
            while !finished && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            T.ok("L-04  autosaving a remote document returns rather than hanging", finished)
            T.ok("L-05  and reports no error, because it did nothing",
                 autosaveError == nil, String(describing: autosaveError))
            T.ok("L-06  and wrote nothing to the far machine's path on THIS disk",
                 !FileManager.default.fileExists(atPath: remoteURL.path))
        }

        // L-07: the choke point every local write goes through. Autosave is one
        // caller; termination review and Save As are others. Refusing here is
        // what makes "never writes it locally" true rather than likely.
        if let doc = escaped {
            var refused = false
            do {
                try doc.writeSafely(to: remoteURL, ofType: "net.daringfireball.markdown", for: .autosaveInPlaceOperation)
            } catch {
                refused = true
            }
            T.ok("L-07  a direct local write of a remote document is refused", refused)
            T.ok("L-08  and still nothing exists at that path",
                 !FileManager.default.fileExists(atPath: remoteURL.path))
        }

        // L-09: a local document is untouched by any of this — it must still
        // autosave in place, which is most of why NSDocument is here.
        let local = CrookDocument()
        T.ok("L-09  local documents still autosave in place",
             CrookDocument.autosavesInPlace && local.remoteProviderID == nil)

        escaped?.close()
        T.ok("L-10  closing releases it, so navigation does not leak documents",
             !NSDocumentController.shared.documents.contains { $0 === escaped })
    }
}
