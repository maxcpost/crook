import AppKit

/// NSDocument gives autosave-in-place, version browsing and the proxy icon. It
/// also conforms to NSFilePresenter, which is the real reason this app is
/// native: another process rewrites these files constantly, and NSFilePresenter
/// is the only cooperative protocol for that (D-01, verified).
///
/// The document does NOT own the window. WorkspaceWindowController does, and
/// documents attach and detach beneath it as you navigate.
@objc(CrookDocument)
final class CrookDocument: NSDocument {

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
    /// nothing across a network. Autosave-in-place is disabled for these,
    /// because writing to another machine on a timer is not something to do
    /// without being asked.
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
        let doc = CrookDocument()
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
        guard let providerID = remoteProviderID, let url = fileURL else {
            super.save(sender); return
        }
        let p = Providers.current
        guard p.id == providerID, p.isConnected else {
            // Never silently. The buffer is authoritative and stays exactly as
            // it is; the user decides what to do about the connection.
            let a = NSAlert()
            a.messageText = "Not connected to that machine."
            a.informativeText = "Your edits are still here and unchanged. Reconnect, and save again."
            a.addButton(withTitle: "OK")
            if let w = windowControllers.first?.window { a.beginSheetModal(for: w) { _ in } }
            else { a.runModal() }
            return
        }
        do {
            let bytes = try data(ofType: "net.daringfireball.markdown")
            try p.write(bytes, to: url.path)
            updateChangeCount(.changeCleared)
            SeenStore.shared.markSeen(url)
        } catch {
            presentError(error)
        }
    }

    // CodeMirror owns text undo. Transaction.addToHistory.of(false) also calls
    // state.addMapping(), which keeps older undo entries positioned across an
    // external rewrite; reimplementing that in NSUndoManager would mean porting
    // ChangeSet inversion (S03 §5).
    /// The class comment has always said autosave-in-place is disabled for
    /// remote documents. Nothing implemented it, and it did not show because
    /// these documents lived for a few milliseconds. Now that one has a real
    /// owner it lives as long as the window does, and AppKit would autosave it
    /// to `fileURL` — a path naming ANOTHER machine, interpreted against this
    /// disk. Writing another Mac's path onto this one is worse than the crash
    /// it would have replaced.
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
