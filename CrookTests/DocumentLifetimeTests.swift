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

        closing()
        identity()
    }

    /// What happens to unsaved edits when the window closes or the app quits.
    ///
    /// autosavesInPlace is true, so AppKit does not ask "Save changes?" on
    /// close — it autosaves and closes. The remote override of autosave()
    /// reported success while saving nothing, so ⌘W and ⌘Q closed a dirty
    /// remote document and the edits went nowhere. Review finding, and the
    /// worst kind: silent.
    static func closing() {
        T.suite("documents — closing one with unsaved remote edits")

        let url = URL(fileURLWithPath: "/Users/some-other-mac/.claude/skills/x/SKILL.md")
        guard let doc = try? CrookDocument.makeRemote(
            data: Data("# x\n".utf8), url: url, providerID: "ssh:test") else {
            T.ok("L-11  a remote document is built", false); return
        }
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.updateChangeCount(.changeDone)

        // The machine is not current (tests run against the local provider),
        // which is exactly the state after "Work Locally" or a dropped link.
        var saved = false
        if case .saved = doc.saveRemote() { saved = true }
        T.ok("L-11  saving while its machine is not connected refuses", !saved)
        T.ok("L-12  and the edits stay, dirty, in the buffer", doc.isDocumentEdited)

        // A dirty remote document must never be closable through the
        // autosave path, because autosave cannot save it. The decision is
        // exposed so it can be tested without a window.
        T.ok("L-13  a dirty remote document needs the user's answer before it closes",
             doc.needsSaveDecisionBeforeClosing)
        doc.updateChangeCount(.changeCleared)
        T.ok("L-14  a clean one does not", !doc.needsSaveDecisionBeforeClosing)

        let local = CrookDocument()
        local.updateChangeCount(.changeDone)
        T.ok("L-15  and a local document is AppKit's business as always",
             !local.needsSaveDecisionBeforeClosing)

        // The first keystroke. NSDocument asks whether autosaving would be
        // safe, and its default answer inspects fileURL on this disk — a path
        // that, for a remote document, exists on another machine. Left alone
        // it produced "The file cannot be found. You can duplicate this
        // document…" the moment anyone typed.
        // Autosave-in-place is the switch NSDocument keys its whole local-file
        // machinery off — including the private pre-edit check that produced
        // "The file cannot be found. You can duplicate this document…" on the
        // first keystroke in a remote file. It is answered per CLASS, so a
        // remote document has to be a class that answers no.
        T.ok("L-20  a remote document is not an autosaving-in-place document",
             !type(of: doc).autosavesInPlace)
        T.ok("L-21  and a local one still is — that is most of why NSDocument is here",
             CrookDocument.autosavesInPlace)
        T.ok("L-22  a remote document is still a CrookDocument to everything that asks",
             (doc as CrookDocument).remoteProviderID == "ssh:test")
    }

    /// The same absolute path can exist on two machines. /Users/max/.claude on
    /// the laptop and /Users/max/.claude on the mini are different files, and
    /// two documents for them must never be confused for each other.
    static func identity() {
        T.suite("documents — one path, two machines")

        let url = URL(fileURLWithPath: "/Users/max/.claude/CLAUDE.md")
        guard let far = try? CrookDocument.makeRemote(
            data: Data("far\n".utf8), url: url, providerID: "ssh:mini") else {
            T.ok("L-16  a remote document is built", false); return
        }
        defer { far.close() }

        // Navigation dedup: the document a window should reuse for (url, machine).
        T.ok("L-16  a registered remote document is found by its path and machine",
             CrookDocument.registeredRemote(url: url, providerID: "ssh:mini") === far)
        T.ok("L-17  and not by its path on some other machine",
             CrookDocument.registeredRemote(url: url, providerID: "ssh:other") == nil)

        // AppKit dedup: openDocument(withContentsOf:) asks the controller for
        // an already-open document at this URL. While this window is looking
        // at the LOCAL disk, a remote document at the same path must not be
        // the answer, or the mini's text shows up under the laptop's file.
        let controller = CrookDocumentController()
        controller.addDocument(far)
        defer { controller.removeDocument(far) }
        T.ok("L-18  a local open of that path does not get the remote document",
             controller.document(for: url) == nil)

        let here = CrookDocument()
        here.fileURL = url
        controller.addDocument(here)
        defer { controller.removeDocument(here); here.close() }
        T.ok("L-19  it gets the local one, even though the remote was registered first",
             controller.document(for: url) === here)
    }
}
