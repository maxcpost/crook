import AppKit

/// NSDocument gives autosave-in-place, version browsing and the proxy icon. It
/// also conforms to NSFilePresenter, which is the real reason this app is
/// native: another process rewrites these files constantly, and NSFilePresenter
/// is the only cooperative protocol for that (D-01, verified).
///
/// The document does NOT own the window. WorkspaceWindowController does, and
/// documents attach and detach beneath it as you navigate.
@objc(CrookDocument)
class CrookDocument: NSDocument {

    private var loadedText = NSMutableString()
    private var loadedProfile = ByteProfile(lineEnding: .lf, hasFinalNewline: true,
                                            bom: nil, encoding: .utf8, mixedLineEndings: false)
    private weak var editor: EditorViewController?

    override class var autosavesInPlace: Bool { true }

    /// Set when this document's bytes live on another machine.
    ///
    /// A remote document keeps everything that makes CrookDocument correct — the
    /// byte profile, the ownership guard, the dirty tracking — and bypasses only
    /// NSDocument's file plumbing, which is built on a local URL and means
    /// nothing across a network. Such a document is a CrookRemoteDocument, which
    /// is what turns that plumbing off at the level AppKit reads it; this is the
    /// per-instance fact the rest of the code asks about.
    private(set) var remoteProviderID: String?

    /// Build a document for bytes that live on another machine, and give it an
    /// owner.
    ///
    /// The owner is the whole point. A local document is owned by
    /// NSDocumentController — openDocument(withContentsOf:) puts it in the
    /// `documents` array, and that array is what keeps it alive. A remote
    /// document cannot go through that call, so it was built with a bare
    /// CrookDocument() and owned by nobody: `editor.owner` is weak,
    /// NSWindowController.document is unowned(unsafe), and addWindowController
    /// makes the DOCUMENT retain the controller rather than the reverse. Its
    /// lifetime was then whatever AppKit happened to be holding it for, which
    /// is not a lifetime. When it went, the window controller was left with a
    /// dangling pointer and the next file opened crashed inside
    /// -[NSDocument addWindowController:].
    ///
    /// Registering here gives remote and local documents one ownership model
    /// instead of two, and makes install()'s promise that a dirty document
    /// survives navigation true for remote files as well.
    static func makeRemote(data: Data, url: URL, providerID: String) throws -> CrookDocument {
        let doc = CrookRemoteDocument()
        try doc.adoptRemote(data: data, url: url, providerID: providerID)
        NSDocumentController.shared.addDocument(doc)
        return doc
    }

    /// Load bytes that arrived from a provider rather than from a URL.
    /// NSDocumentController cannot open these: it checks the file exists on
    /// THIS machine first, and for a remote path it never does.
    func adoptRemote(data: Data, url: URL, providerID: String) throws {
        try read(from: data, ofType: "net.daringfireball.markdown")
        fileURL = url
        remoteProviderID = providerID
    }

    /// ⌘S. For a local document this is AppKit's job; for a remote one the
    /// write has to go through the provider, and must not clear the dirty flag
    /// until the far side has confirmed it.
    @IBAction override func save(_ sender: Any?) {
        guard remoteProviderID != nil else { super.save(sender); return }
        let outcome = saveRemote()
        if case .saved = outcome { return }
        present(outcome)
    }

    enum RemoteSave {
        case saved
        case notConnected
        case failed(Error)
    }

    /// Write the buffer to the far machine. Anything but .saved means nothing
    /// was written and the buffer is exactly as it was. Presents nothing, so
    /// it can be called from a close sheet, a menu item, or a test alike.
    func saveRemote() -> RemoteSave {
        guard let providerID = remoteProviderID, let url = fileURL else { return .notConnected }
        let p = Providers.current
        guard p.id == providerID, p.isConnected else { return .notConnected }
        do {
            let bytes = try data(ofType: "net.daringfireball.markdown")
            try p.write(bytes, to: url.path)
            updateChangeCount(.changeCleared)
            SeenStore.shared.markSeen(url)
            return .saved
        } catch {
            return .failed(error)
        }
    }

    private func present(_ outcome: RemoteSave) {
        switch outcome {
        case .saved:
            return
        case .failed(let error):
            presentError(error)
        case .notConnected:
            // Never silently. The buffer is authoritative and stays exactly as
            // it is; the user decides what to do about the connection.
            let a = NSAlert()
            a.messageText = "Not connected to that machine."
            a.informativeText = "Your edits are still here and unchanged. Reconnect, and save again."
            a.addButton(withTitle: "OK")
            if let w = windowForSheet { a.beginSheetModal(for: w) { _ in } } else { a.runModal() }
        }
    }

    /// Where this document's bytes live, for a sentence.
    private var machineName: String {
        guard let id = remoteProviderID else { return "this Mac" }
        let p = Providers.current
        return p.id == id ? p.displayName : "the machine it came from"
    }

    // MARK: - closing

    /// True when closing this document would lose something only the user can
    /// decide about. Exposed so the decision can be tested without a window.
    var needsSaveDecisionBeforeClosing: Bool {
        remoteProviderID != nil && isDocumentEdited
    }

    /// autosavesInPlace is true, so AppKit does not ask "Save changes?" on
    /// close — it autosaves and closes. For a remote document autosave() below
    /// returns success having saved nothing, which turned ⌘W and ⌘Q into a
    /// silent discard of every unsaved edit. The question AppKit skips is asked
    /// here instead, in its own words, and the answer goes back through the
    /// same delegate/selector contract AppKit expects.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        guard needsSaveDecisionBeforeClosing else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector,
                           contextInfo: contextInfo)
            return
        }
        let finish = { (shouldClose: Bool) in
            Self.answer(delegate, shouldCloseSelector, document: self,
                        shouldClose: shouldClose, contextInfo: contextInfo)
        }
        let name = fileURL?.lastPathComponent ?? displayName ?? "this file"
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \(name)?"
        alert.informativeText = "This file lives on \(machineName). "
            + "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let decide: (NSApplication.ModalResponse) -> Void = { [self] response in
            switch response {
            case .alertFirstButtonReturn:
                let outcome = saveRemote()
                if case .saved = outcome { finish(true) } else { present(outcome); finish(false) }
            case .alertThirdButtonReturn:
                updateChangeCount(.changeCleared)
                finish(true)
            default:
                finish(false)
            }
        }
        if let w = windowForSheet { alert.beginSheetModal(for: w, completionHandler: decide) }
        else { decide(alert.runModal()) }
    }

    /// -document:shouldClose:contextInfo:, sent by hand. There is no Swift
    /// spelling for "call this selector with these three arguments".
    private static func answer(_ delegate: Any, _ selector: Selector?, document: NSDocument,
                               shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let sel = selector, let target = delegate as? NSObject, target.responds(to: sel),
              let imp = target.method(for: sel) else { return }
        typealias Reply = @convention(c) (AnyObject, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(imp, to: Reply.self)(target, sel, document, shouldClose, contextInfo)
    }

    /// Every change to the dirty state, both directions, tells the window.
    /// AppKit's own notification of window controllers differs between
    /// autosaving and non-autosaving documents; this does not.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        for wc in windowControllers {
            (wc as? WorkspaceWindowController)?.documentEditedStateChanged()
        }
    }

    // MARK: - identity

    /// The registered document for a path ON a machine, if there is one.
    ///
    /// A dirty document navigated away from stays registered so its edits
    /// survive; coming back to that path must find it rather than fetch the
    /// far machine's bytes and show those under the same name. The machine is
    /// part of the key, because the same path exists on more than one.
    static func registeredRemote(url: URL, providerID: String) -> CrookDocument? {
        let want = url.standardizedFileURL.path
        return NSDocumentController.shared.documents.first { d in
            guard let c = d as? CrookDocument, c.remoteProviderID == providerID,
                  let u = c.fileURL else { return false }
            return u.standardizedFileURL.path == want
        } as? CrookDocument
    }

    // MARK: - file presentation

    // NSDocument is an NSFilePresenter for its fileURL, and reacts to that path
    // changing on THIS disk: a clean document is reverted from the file, a
    // deleted one is closed. A remote document's fileURL names a path on
    // another machine, and when the same path happens to exist here — the same
    // username on both Macs is all it takes — those reactions would replace
    // the mini's text with the laptop's, or close the document because a
    // local file went away. The agent on the far side reports changes to the
    // file that actually backs this document; the local presenter is ignored.

    override func presentedItemDidChange() {
        guard remoteProviderID == nil else { return }
        super.presentedItemDidChange()
    }

    override func presentedItemDidMove(to newURL: URL) {
        guard remoteProviderID == nil else { return }
        super.presentedItemDidMove(to: newURL)
    }

    override func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        guard remoteProviderID == nil else { completionHandler(nil); return }
        super.accommodatePresentedItemDeletion(completionHandler: completionHandler)
    }

    // CodeMirror owns text undo. Transaction.addToHistory.of(false) also calls
    // state.addMapping(), which keeps older undo entries positioned across an
    // external rewrite; reimplementing that in NSUndoManager would mean porting
    // ChangeSet inversion (S03 §5).
    /// A CrookRemoteDocument reports autosavesInPlace false, so AppKit never
    /// schedules this for one. Kept as a second line: if a remote document ever
    /// reaches here anyway, it must not write another machine's path onto this
    /// disk, and the write guard below is the third.
    override func autosave(withImplicitCancellability implicitlyCancellable: Bool,
                           completionHandler: @escaping (Error?) -> Void) {
        guard remoteProviderID == nil else { completionHandler(nil); return }
        super.autosave(withImplicitCancellability: implicitlyCancellable,
                       completionHandler: completionHandler)
    }

    /// Every local write NSDocument performs funnels through here — autosave,
    /// Save As, and the review AppKit runs at termination. Refusing at the
    /// choke point is what makes "a remote file is never written locally" a
    /// guarantee rather than a list of callers someone remembered to cover.
    /// ⌘S is unaffected: save(_:) sends the bytes over the provider and never
    /// reaches this.
    override func writeSafely(to url: URL, ofType typeName: String,
                              for saveOperation: NSDocument.SaveOperationType) throws {
        guard remoteProviderID == nil else {
            throw NSError(domain: "Crook", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "This file lives on another machine.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "Save writes it back over the connection. Crook does not copy it onto this Mac.",
            ])
        }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }

    override var hasUndoManager: Bool {
        get { false }
        set { }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let (text, profile) = try ByteCodec.decode(data)
        loadedText = text
        loadedProfile = profile
        if let editor { editor.bridge.load(text: text, profile: profile) }
    }

    override func data(ofType typeName: String) throws -> Data {
        // Only the document the editor is CURRENTLY showing may read its
        // buffer. There is one shared editor, and a document that has been
        // detached would otherwise serialise the next file's text into its own
        // path — silently replacing the contents of a file you were editing
        // with the contents of the one you opened after it.
        if let b = editor?.bridge, editor?.owner === self {
            // Everything typed must be in the buffer before it is encoded.
            b.flushPendingEdits()
            return try b.data()
        }
        return try ByteCodec.encode(loadedText, profile: loadedProfile)
    }

    /// Point an existing editor at this document's contents.
    /// Called when this document loses the shared editor. Its text is captured
    /// so a later save writes what the user actually had, not the next file.
    func detachFromEditor() {
        if let b = self.editor?.bridge, self.editor?.owner === self {
            loadedText = NSMutableString(string: b.text as String)
            loadedProfile = b.profile
        }
        self.editor = nil
    }

    func attach(to editor: EditorViewController) {
        // Grab the previous snapshot BEFORE setOpenDocument overwrites it.
        let previous = fileURL.flatMap { SeenStore.shared.snapshot(for: $0) }
        let changed = fileURL.map { SeenStore.shared.hasChangedSinceOpened($0) } ?? false
        WorkspaceWindowController.shared.noteSnapshotBeforeOpen(previous)
        SeenStore.shared.setOpenDocument(fileURL)

        // Whoever held the editor before this must capture its own text first.
        if let prior = editor.owner as? CrookDocument, prior !== self {
            prior.detachFromEditor()
        }
        editor.owner = self
        self.editor = editor
        editor.bridge.onDirty = { [weak self] dirty in
            self?.updateChangeCount(dirty ? .changeDone : .changeCleared)
        }
        // Recompute the subtitle only when the edit touched the frontmatter
        // region. Typing in the body cannot change what makes a file load, and
        // the gate uses the SAME cap the frontmatter scanner does.
        editor.bridge.onEngage = { WorkspaceWindowController.shared.markEngaged() }
        editor.bridge.onEdit = { [weak self, weak editor] lowest in
            if lowest < Frontmatter.scanLimit { WorkspaceWindowController.shared.refreshReach() }
            self?.scheduleScan(editor)
        }
        editor.bridge.onReady = { [weak self, weak editor] in
            guard let self, let editor, editor.owner === self else { return }
            // After a web content process crash the bridge still holds the
            // canonical text; reseeding from loadedText would throw away every
            // edit made since the file was opened.
            let live = editor.bridge.text
            if live.length > 0 {
                editor.bridge.load(text: NSMutableString(string: live as String),
                                   profile: editor.bridge.profile)
            } else {
                editor.bridge.load(text: self.loadedText, profile: self.loadedProfile)
            }
            // Put the caret in the document. Opening a file from Finder or the
            // command line never went through retarget(), which is the only
            // path that focused the editor, so a launched-into file could be
            // read but not typed into until you clicked it.
            editor.focusEditor()
        }
        editor.bridge.load(text: loadedText, profile: loadedProfile)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak editor] in
            editor?.bridge.pushDiagnostics(for: self?.fileURL)
        }
        // If it moved while you were away, lead with what moved.
        if changed, previous != nil {
            let expected = fileURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WorkspaceWindowController.shared.showChanges(for: expected)
            }
        }
    }

    /// Rescan on a trailing delay: a path is not dead until you stop typing it.
    private var scanWork: DispatchWorkItem?
    private func scheduleScan(_ editor: EditorViewController?) {
        scanWork?.cancel()
        let w = DispatchWorkItem { [weak self, weak editor] in
            editor?.bridge.pushDiagnostics(for: self?.fileURL)
        }
        scanWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// The bytes Crook would write right now — used to tell a real external
    /// change from our own autosave landing.
    func currentText() -> String { (editor?.bridge.text as String?) ?? (loadedText as String) }

    func currentBytes() -> Data {
        (try? data(ofType: "net.daringfireball.markdown")) ?? Data()
    }

    /// The conflict state's exit. Without this the red indicator is a dead end:
    /// it tells you the disk moved and gives you nothing to do about it.
    @IBAction func reloadFromDiskDiscardingEdits(_ sender: Any?) {
        reloadFromDisk()
        WorkspaceWindowController.shared.markEngaged()
    }

    /// Re-read from disk into the live editor, preserving the caret.
    func reloadFromDisk() {
        guard let url = fileURL,
              let data = Providers.current.contents(url.path),
              let (text, profile) = try? ByteCodec.decode(data) else { return }
        loadedText = text
        loadedProfile = profile
        editor?.bridge.load(text: text, profile: profile)
        updateChangeCount(.changeCleared)
        SeenStore.shared.markSeen(url)
    }

    override func makeWindowControllers() {
        // One window, always. If another document currently holds it, detach
        // that one first — a clean, now-windowless document is allowed to go.
        let wc = WorkspaceWindowController.shared
        if let previous = wc.document as? CrookDocument, previous !== self {
            previous.removeWindowController(wc)
            if previous.windowControllers.isEmpty && !previous.isDocumentEdited {
                previous.close()
            }
        }
        addWindowController(wc)
        attach(to: wc.editor)
        wc.syncTitle(fileURL)
        if ProcessInfo.processInfo.environment["CROOK_TRACE_TREE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { wc.rail.selfTestExpansion() }
        }
    }
}

/// A document whose bytes live on another machine.
///
/// It changes exactly one thing: the class-level answer to autosavesInPlace.
/// That answer is not a preference — it is the switch NSDocument keys its
/// entire local-file machinery off. With it on, every change-count update
/// first runs a private check that the file at fileURL still exists on this
/// disk, and for a path that names a file on another Mac that check fails on
/// the first keystroke with "The file cannot be found. You can duplicate this
/// document…". No public override reaches that check; the header's
/// checkAutosavingSafety is a different one, and was never invoked. Answering
/// false here is what the class comment has promised since the feature was
/// written, made true where AppKit reads it.
///
/// Everything else a remote document needs is on CrookDocument and keyed off
/// remoteProviderID: the close prompt that replaces the one AppKit skips for
/// autosaving documents, the write over the provider, the guards on the local
/// write path and the file-presenter reactions.
@objc(CrookRemoteDocument)
final class CrookRemoteDocument: CrookDocument {
    override class var autosavesInPlace: Bool { false }
}
