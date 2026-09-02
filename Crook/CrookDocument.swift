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

    // CodeMirror owns text undo. Transaction.addToHistory.of(false) also calls
    // state.addMapping(), which keeps older undo entries positioned across an
    // external rewrite; reimplementing that in NSUndoManager would mean porting
    // ChangeSet inversion (S03 §5).
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
              let data = FileManager.default.contents(atPath: url.path),
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
