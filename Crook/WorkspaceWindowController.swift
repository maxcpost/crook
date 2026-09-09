import AppKit

/// One window: a rail that persists, and a document that swaps inside it.
///
/// NSDocument binds a document to its window controllers, so navigating to a
/// file used to mean a whole new window — with a duplicate rail — and a tab bar
/// to manage the pile. No Mac app works that way: Finder, Xcode and Mail keep
/// one window whose sidebar persists while content changes in the pane.
///
/// So the window controller is the durable thing here, and documents are
/// detached and attached beneath it.
final class WorkspaceWindowController: NSWindowController {

    /// There is exactly one workspace window. The rail is the durable surface;
    /// documents come and go beneath it.
    static let shared = WorkspaceWindowController()

    let rail = RailViewController()
    let editor = EditorViewController()

    private var isRetargeting = false
    /// Resolved once per document; the keystroke path never touches the disk.
    private var reachContext: ReachClassifier.Context?

    /// Whether the bytes on disk still match what we loaded.
    enum SyncState { case inSync, reloaded, conflict, vanished }
    private var syncState: SyncState = .inSync { didSet { refreshProxyIcon() } }
    private var settleBack: DispatchWorkItem?

    private lazy var watcher = FileWatcher { [weak self] change in
        self?.handleExternalChange(change)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)

        let split = NSSplitViewController()
        split.splitView.dividerStyle = .thin

        let railItem = NSSplitViewItem(viewController: rail)
        railItem.minimumThickness = 232
        railItem.maximumThickness = 340
        railItem.canCollapse = true
        railItem.holdingPriority = NSLayoutConstraint.Priority(260)

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 420

        split.addSplitViewItem(railItem)
        split.addSplitViewItem(editorItem)

        // No toolbar. An NSToolbar with zero items still reserves a band, and
        // stacked under the title and a tab bar it produced three rows of chrome
        // carrying nothing. The title row alone is enough.
        window.toolbar = nil
        // No window tabs. Navigation retargets this window, so a second document
        // never opens and the tab bar has nothing to show.
        window.tabbingMode = .disallowed
        // The hairline across the top of the sidebar is AppKit's titlebar
        // separator. With a flush sidebar carrying its own material there is
        // nothing for it to separate.
        window.titlebarSeparatorStyle = .none
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1120, height: 740))
        window.minSize = NSSize(width: 720, height: 460)
        // Documents must not restore their own windows — each restored one
        // would build another rail. The frame is remembered; the pile is not.
        window.isRestorable = false
        window.setFrameAutosaveName("CrookWorkspace")
        window.center()

        rail.onOpen = { [weak self] url in self?.retarget(to: url) }
        rail.onConnect = { [weak self] in self?.beginConnect() }
        rail.onUseLocal = { [weak self] in self?.switchToLocal() }
        rail.onSwitchTo = { [weak self] host in self?.reconnect(to: host) }
        syncMachine()
        editor.showEmptyState(true, onAddProject: { [weak self] in self?.rail.beginAddProject() },
                              onConnect: { [weak self] in self?.beginConnect() })

        // Re-read the tree when Crook comes forward.
        //
        // Without this the rail only refreshed on launch, on opening a file, and
        // after adding a project — so the normal loop of this whole product,
        // leaving Crook to let Claude Code work and coming back, showed stale
        // change marks until you happened to click something. The marks are
        // computed from mtime and a content hash, so a rebuild is the only thing
        // that surfaces them.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        dumpViews()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func dumpViews() {
        guard ProcessInfo.processInfo.environment["CROOK_DUMP_VIEWS"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let w = self?.window, let root = w.contentView else { return }
            NSLog("Crook: --- view dump; window frame \(w.frame) contentLayoutRect \(w.contentLayoutRect)")
            NSLog("Crook: titlebarSeparatorStyle=\(w.titlebarSeparatorStyle.rawValue) toolbar=\(String(describing: w.toolbar))")
            func walk(_ v: NSView, _ depth: Int) {
                let pad = String(repeating: "  ", count: depth)
                var bg = "-"
                if let l = v.layer, let c = l.backgroundColor { bg = "\(c)" }
                let border = v.layer.map { "border=\($0.borderWidth)" } ?? ""
                NSLog("Crook: \(pad)\(type(of: v)) frame=\(v.frame) wantsLayer=\(v.wantsLayer) bg=\(bg) \(border) hidden=\(v.isHidden) alpha=\(v.alphaValue)")
                for s in v.subviews where s.frame.height < 6 || depth < 4 { walk(s, depth + 1) }
            }
            walk(root, 0)
            // anything short and wide near the top of the sidebar is the culprit
            NSLog("Crook: --- candidate hairlines (height <= 2)")
            func hairlines(_ v: NSView) {
                if v.frame.height > 0 && v.frame.height <= 2 && v.frame.width > 100 {
                    let inWindow = v.convert(v.bounds, to: nil)
                    NSLog("Crook: HAIRLINE \(type(of: v)) windowRect=\(inWindow) bg=\(String(describing: v.layer?.backgroundColor))")
                }
                v.subviews.forEach(hairlines)
            }
            hairlines(root)
        }
    }

    /// Swap the document under this window without disturbing the rail.
    /// Throttled: activation fires for every ⌘-tab, and a full tree walk on each
    /// one would be work nobody asked for. A second is far below the interval at
    /// which an agent rewrites files and far above the rate a person switches
    /// windows by accident.
    private var lastActiveRefresh: TimeInterval = 0

    @objc private func appBecameActive() {
        let now = Date().timeIntervalSince1970
        guard now - lastActiveRefresh > 1.0 else { return }
        lastActiveRefresh = now
        rail.reload()
    }

    // MARK: - machines

    func beginConnect() {
        let sheet = ConnectSheet()
        sheet.onConnected = { [weak self] provider in self?.adopt(provider) }
        contentViewController?.presentAsSheet(sheet)
    }

    /// Point the whole window at another machine.
    ///
    /// One machine per window, so this is a clean swap rather than a merge: the
    /// open document belonged to the previous machine and is closed, because a
    /// buffer whose file lives somewhere no longer reachable is a trap. Its
    /// bytes are still on that machine, untouched.
    func adopt(_ provider: RemoteProvider) {
        closeCurrentDocument()
        provider.onTreeChanged = { [weak self] in self?.rail.reload() }
        provider.onPathsChanged = { [weak self] paths in
            // The agent reports directories as well as files, so match on
            // prefix: a write to the open file arrives as its containing
            // directory when the event is coalesced.
            guard let self, let open = (self.document as? CrookDocument)?.fileURL else { return }
            guard paths.contains(where: { open.path == $0 || open.path.hasPrefix($0 + "/") }) else { return }
            self.handleExternalChange(.written)
        }
        provider.onDisconnected = { [weak self] message in
            DispatchQueue.main.async { self?.handleDisconnect(message) }
        }
        Providers.use(provider)
        rail.reload()
        syncMachine()
        provider.refresh { [weak self] in
            self?.rail.reload()
            self?.syncMachine()
        }
        provider.startWatching()
    }

    /// Jump straight to a machine already in the list, without the sheet.
    func reconnect(to host: String) {
        Machines.shared.connect(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let p): self.adopt(p)
            // A saved machine that will not answer silently is worse than one
            // that asks: fall back to the sheet with the name filled in, where
            // the error can actually be read.
            case .failure: self.beginConnect()
            }
        }
    }

    func switchToLocal() {
        closeCurrentDocument()
        Machines.shared.disconnect()
        rail.reload()
        syncMachine()
    }

    private func closeCurrentDocument() {
        guard let doc = document as? CrookDocument else { return }
        doc.detachFromEditor()
        doc.removeWindowController(self)
        if !doc.isDocumentEdited { doc.close() }
        editor.showEmptyState(true, onAddProject: { [weak self] in self?.rail.beginAddProject() },
                              onConnect: { [weak self] in self?.beginConnect() })
        syncTitle(nil)
    }

    /// The machine name lives in the window subtitle: present without being
    /// chrome, and absent entirely when you are looking at your own Mac, which
    /// is the case that should feel like no feature at all.
    func syncMachine() {
        let p = Providers.current
        window?.subtitle = p.isLocal ? "" : p.displayName
        rail.setMachine(name: p.isLocal ? nil : p.displayName, connected: p.isConnected)
    }

    private func handleDisconnect(_ message: String) {
        syncMachine()
        let doc = document as? CrookDocument
        let alert = NSAlert()
        alert.messageText = message
        if doc?.isDocumentEdited == true {
            // The buffer is authoritative and is never discarded to resolve a
            // connection problem.
            alert.informativeText = "Your unsaved edits are still here. They have not reached "
                + "that machine yet — reconnect and save, or copy them somewhere safe."
            alert.addButton(withTitle: "Reconnect")
            alert.addButton(withTitle: "Keep Editing")
        } else {
            alert.informativeText = "Nothing was lost."
            alert.addButton(withTitle: "Reconnect")
            alert.addButton(withTitle: "Work Locally")
        }
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                if let host = Machines.shared.last {
                    Machines.shared.connect(host: host) { result in
                        if case .success(let p) = result { self.adopt(p) }
                        else { self.beginConnect() }
                    }
                } else {
                    self.beginConnect()
                }
            } else if doc?.isDocumentEdited != true {
                self.switchToLocal()
            }
        }
    }

    func retarget(to url: URL) {
        guard !isRetargeting else { return }
        let current = (document as? CrookDocument)?.fileURL
        guard current != url else { editor.focusEditor(); return }

        isRetargeting = true

        // A remote file cannot go through NSDocumentController: it checks the
        // file exists on THIS machine before it will build a document, and for a
        // path on the mini it never does. The document is constructed directly
        // from bytes the provider fetched instead — everything after that point
        // is identical, because CrookDocument already reads and writes bytes
        // rather than URLs.
        let provider = Providers.current
        if !provider.isLocal {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let data = provider.contents(url.path)
                DispatchQueue.main.async {
                    guard let self else { return }
                    defer { self.isRetargeting = false }
                    guard let data else {
                        NSLog("Crook: could not read \(url.path) from \(provider.displayName)")
                        return
                    }
                    let next: CrookDocument
                    do {
                        next = try CrookDocument.makeRemote(
                            data: data, url: url, providerID: provider.id)
                    } catch {
                        NSLog("Crook: could not decode \(url.lastPathComponent): \(error)")
                        return
                    }
                    self.install(next, at: url)
                }
            }
            return
        }

        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { [weak self] doc, _, err in
            guard let self else { return }
            defer { self.isRetargeting = false }
            if let err {
                NSLog("Crook: retarget \(url.lastPathComponent) failed: \(err)")
                return
            }
            guard let next = doc as? CrookDocument else { return }
            guard next !== self.document as? CrookDocument else { return }
            self.install(next, at: url)
        }
    }

    /// Swap the window onto a document, wherever its bytes came from.
    private func install(_ next: CrookDocument, at url: URL) {
        if let previous = document as? CrookDocument, previous !== next {
            previous.detachFromEditor()
            previous.removeWindowController(self)
            // Let a clean, now-windowless document go. A dirty one stays alive
            // so its unsaved edits are still recoverable.
            if previous.windowControllers.isEmpty && !previous.isDocumentEdited {
                previous.close()
            }
        }
        // Drop whatever the window still points at before attaching the next
        // document, unconditionally.
        //
        // This is the line the crash happened on. -[NSDocument
        // addWindowController:] reads the controller's CURRENT document and
        // sends it removeWindowController:, and `document` is unowned(unsafe) —
        // AppKit does not check it, because it trusts that a document which
        // died removed itself first. The cleanup above only runs when the cast
        // to CrookDocument succeeds, so anything else there was carried
        // straight into AppKit's hands; a freed document whose memory had been
        // reused by CoreUI arrived as _CUIInternalLinkRendition and took the
        // app down.
        //
        // Assigning nil costs nothing and never messages the old value, so it
        // is safe even when that value is exactly the thing we must not touch.
        document = nil
        next.addWindowController(self)
        next.attach(to: editor)
        syncTitle(url)
        // Reload so the delta on the file just opened clears; expansion and
        // selection are preserved across it.
        rail.reload()
        rail.selectFile(url)
        editor.focusEditor()
    }

    /// "Atlas ▸ CLAUDE.md", not "CLAUDE.md".
    ///
    /// 21 of the fixture's files are named CLAUDE.md and 34 are SKILL.md — the
    /// filename alone identifies almost nothing in this corpus. The proxy icon
    /// still carries the full path for anyone who wants it.
    func syncTitle(_ url: URL?) {
        editor.showEmptyState(url == nil, onAddProject: { [weak self] in self?.rail.beginAddProject() },
                              onConnect: { [weak self] in self?.beginConnect() })
        window?.representedURL = url
        // kqueue only means anything for a file on this machine. A remote
        // document is watched by the agent instead, which is the only side that
        // can see the writes.
        watcher.watch(Providers.current.isLocal ? url : nil)
        syncState = .inSync
        synchronizeWindowTitleWithDocumentName()
        reachContext = url.map { ReachClassifier.Context.resolve($0) }
        refreshReach()
    }

    /// Reached By. NSWindow.subtitle does not add a line: on a .titled window
    /// with no toolbar, AppKit concatenates title and subtitle into the single
    /// titlebar field, measured 32pt with and without. Zero pixels, zero new
    /// surfaces, so the two-persistent-affordance budget is unchanged.
    /// The reach sentence lives in the editor's bottom-right readout, not in
    /// the titlebar. The title answers "which file"; the readout answers "why
    /// does Claude read it". Two different questions, and stacking them made
    /// one long line that was hard to scan for either.
    func refreshReach() {
        guard let ctx = reachContext else { editor.setReach(""); return }
        editor.setReach(ReachClassifier.subtitle(ctx, text: editor.bridge.text as String))
    }

    /// NSWindowController regenerates the title from the document, so setting
    /// window.title directly is overwritten. This is the hook that sticks.
    // MARK: - the proxy icon says whether you are looking at the current bytes

    /// The default proxy icon is a picture of a page — it says "this is a file",
    /// which you knew. Replaced with the one thing about the open document that
    /// changes and matters: whether the bytes on disk still match what you are
    /// reading. representedURL stays set, so ⌘-click for the path menu and
    /// drag-to-Finder are unaffected.
    private func refreshProxyIcon() {
        guard let button = window?.standardWindowButton(.documentIconButton) else { return }
        let symbol: String, tint: NSColor, help: String
        switch syncState {
        case .inSync:
            symbol = "circle.fill"; tint = .tertiaryLabelColor
            help = "You are reading the bytes that are on disk"
        case .reloaded:
            symbol = "arrow.trianglehead.2.clockwise"; tint = .systemYellow
            let d = lastDelta.map { " · \(SeenStore.format($0)) lines" } ?? ""
            help = "Claude Code rewrote this file\(d) · reloaded"
        case .conflict:
            symbol = "exclamationmark.triangle.fill"; tint = .systemRed
            help = "Changed on disk while you were editing · ⌘R takes the disk version"
        case .vanished:
            symbol = "questionmark.circle"; tint = .systemRed
            help = "This file is no longer on disk"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [tint]))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(cfg)
        button.toolTip = help
    }

    private func handleExternalChange(_ change: FileWatcher.Change) {
        guard let doc = document as? CrookDocument, let url = doc.fileURL else { return }
        if case .vanished = change {
            syncState = .vanished
            // Keep watching. A branch switch or a delete-then-rewrite removes
            // the path for longer than the grace period, and without this the
            // watcher stays dead for the rest of the session.
            watcher.watch(url)
            return
        }

        if doc.isDocumentEdited {
            // Never silently discard the user's edits.
            syncState = .conflict
            return
        }
        // Clean buffer: reload and keep the reader's place, then say WHICH
        // lines moved. "Something changed" is not reviewable; "these four lines
        // changed" is, and reviewing agent writes is the actual job here.
        guard let data = Providers.current.contents(url.path),
              data != doc.currentBytes() else { return }
        let before = doc.currentText()
        doc.reloadFromDisk()
        let after = doc.currentText()

        if let d = LineDiff.between(before, after), !d.isEmpty {
            let lines = Array(d.firstChanged...max(d.firstChanged, d.lastChanged))
            editor.bridge.pushChangedLines(lines)
            lastDelta = d.delta
        } else {
            lastDelta = 0
        }
        syncState = .reloaded
        // NO TIMER. The mark holds until the reader engages with the document —
        // a six-second decay expires precisely while they are in the terminal,
        // which is the entire situation this exists for.
    }

    /// The reader has looked. Same act of ratification the rail uses.
    func markEngaged() {
        // .conflict must clear too. It did not, so ⌘R — the exit the tooltip
        // itself advertises — took the disk version and left the red triangle
        // up forever.
        guard syncState == .reloaded || syncState == .conflict else { return }
        syncState = .inSync
        lastDelta = nil
    }

    private var lastDelta: Int?

    /// Show what changed since this file was last opened here. Presented
    /// automatically when you open a file the agent has rewritten in the
    /// meantime — that is the moment the information is worth something — and
    /// available afterwards from View ▸ Show Changes.
    @objc func showChanges(_ sender: Any?) {
        showChanges(for: nil)
    }

    /// - Parameter expected: when non-nil, do nothing unless this is still the
    ///   open document. The auto-present is deferred half a second, and clicking
    ///   a second file inside that window used to pop the change view for the
    ///   wrong file.
    func showChanges(for expected: URL?) {
        guard let doc = document as? CrookDocument, let url = doc.fileURL else { return }
        if let expected, expected != url { return }
        guard let old = pendingSnapshot ?? SeenStore.shared.snapshot(for: url) else {
            NSSound.beep(); return
        }
        let new = doc.currentText()
        guard old != new else { NSSound.beep(); return }
        editor.showDiff(old: old, new: new,
                        title: Workspace.shared.breadcrumb(for: url).joined(separator: " ▸ "))
    }

    /// The snapshot as it was BEFORE this open overwrote it. markSeen runs on
    /// attach, so by the time anything can ask, the stored snapshot is already
    /// the new content — this holds the previous one for exactly one open.
    private var pendingSnapshot: String?

    func noteSnapshotBeforeOpen(_ text: String?) { pendingSnapshot = text }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        guard let url = (document as? NSDocument)?.fileURL else { return displayName }
        let crumbs = Workspace.shared.breadcrumb(for: url)
        if crumbs.count > 1 { return crumbs.joined(separator: " ▸ ") }
        // Not in the workspace tree — a file opened from Finder, say.
        if let context = Workspace.shared.contextLabel(for: url) {
            return "\(context) ▸ \(displayName)"
        }
        return displayName
    }
}
