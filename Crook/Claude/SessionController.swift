import AppKit

/// Edit with Claude, for the workspace window.
///
/// The title bar button, the popover, the checks before Terminal opens, watch
/// mode, and what happens when a session ends. A session belongs to Terminal
/// and outlives Crook, so this object never owns one: SessionRegistry knows
/// what is running, and everything shown here is recomputed from that, from
/// the open document, and from the disk.
final class SessionController: NSObject, NSPopoverDelegate {

    private unowned let wc: WorkspaceWindowController
    private let registry: SessionRegistry
    let accessory = ClaudeButton()

    private var popover: NSPopover?
    /// Requests typed but not sent, per file, until Crook quits.
    private var drafts: [String: String] = [:]
    /// The file whose checks are running. One start at a time.
    private var starting: URL?
    private var placements: [UUID: TerminalLauncher.Placement] = [:]
    private var nudgeUntil = Date.distantPast
    private var nudgeEnds: DispatchWorkItem?

    private static let startedOnceKey = "CrookClaudeStartedOnce"
    private static let startedCountKey = "CrookClaudeStartedCount"

    init(window wc: WorkspaceWindowController, registry: SessionRegistry = .shared) {
        self.wc = wc
        self.registry = registry
        super.init()
        accessory.layoutAttribute = .trailing
        wc.window?.addTitlebarAccessoryViewController(accessory)
        accessory.onClick = { [weak self] optionHeld in self?.buttonClicked(skipAsking: optionHeld) }
        registry.onChange = { [weak self] s in self?.sessionChanged(s) }
        registry.fileChanged = { s in Self.differsFromBaseline(s) }
        wc.editor.bridge.onReadOnlyAttempt = { [weak self] in self?.nudge() }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                                               name: NSWindow.didResizeNotification, object: wc.window)
        windowResized()
        #if CROOK_E2E
        DispatchQueue.main.async { [weak self] in self?.e2eStart() }
        #endif
    }

    // MARK: - the open file

    /// The document the editor is showing. A window closed with its red
    /// button keeps `document` set while showing the empty state; only the
    /// editor's owner says what is really on screen.
    private var document: CrookDocument? {
        guard let doc = wc.document as? CrookDocument, wc.editor.owner === doc else { return nil }
        return doc
    }

    private func providerID(of doc: CrookDocument) -> String {
        doc.remoteProviderID ?? Providers.local.id
    }

    private func session(for doc: CrookDocument) -> ClaudeSession? {
        guard let url = doc.fileURL else { return nil }
        return registry.session(for: url.path, providerID: providerID(of: doc))
    }

    /// A session to watch or review for this file, on the machine the window
    /// is looking at.
    func hasSession(for url: URL) -> Bool {
        registry.session(for: url.path, providerID: Providers.current.id) != nil
    }

    /// Make the button, the banner and the editor agree with the open file.
    func refresh() {
        #if CROOK_E2E
        defer { e2eNote() }
        #endif
        guard let doc = document, let url = doc.fileURL else {
            accessory.setMode(.hidden)
            wc.editor.setBanner(nil)
            wc.editor.bridge.setReadOnly(false)
            return
        }
        if starting == url {
            accessory.setMode(.opening)
            wc.editor.bridge.setReadOnly(true)
            wc.editor.setBanner(nil)
            return
        }
        let s = session(for: doc)
        switch s?.state {
        case .opening?: accessory.setMode(.opening)
        case .running?, .stopping?: accessory.setMode(.running)
        default: accessory.setMode(wc.fileVanished ? .disabled : .idle)
        }
        wc.editor.bridge.setReadOnly(s?.isLive == true)
        guard let s, let content = banner(for: s, doc: doc) else {
            wc.editor.setBanner(nil)
            return
        }
        wc.editor.setBanner(content,
                            onAction: { [weak self] action in self?.bannerAction(action) },
                            onOpenFile: { [weak self] relative in self?.openNearby(relative, from: s) })
    }

    private func banner(for s: ClaudeSession, doc: CrookDocument) -> BannerContent? {
        let current = doc.currentText()
        let baseline = s.baseline.flatMap { try? ByteCodec.decode($0).0 as String } ?? current
        let tally = SessionReview.tally(baseline: baseline, current: current)
        let connected = Self.provider(for: s) != nil
        // Undo and Redo are offered only while what is on screen, with nothing
        // unsaved, is the version they replace. Compared as text: re-encoding
        // the buffer can't reproduce a file with mixed line endings byte for
        // byte. The swap itself still checks the disk's exact bytes.
        let final = s.finalBytes
        let finalText = final.flatMap { try? ByteCodec.decode($0).0 as String }
        let clean = !doc.isDocumentEdited
        let undo = SessionCopy.swapAvailability(verb: "undo", haveVersion: final != nil, fileVanished: s.fileVanished,
                                                connected: connected, machine: s.record.machineName,
                                                diskMatches: clean && finalText == current)
        let redo = SessionCopy.swapAvailability(verb: "redo", haveVersion: final != nil, fileVanished: s.fileVanished,
                                                connected: connected, machine: s.record.machineName,
                                                diskMatches: clean && s.baseline != nil && baseline == current)
        let nearby = s.record.alsoChanged.map { SessionPlan.relativePath($0, from: s.record.workingDirectory) }
        return SessionCopy.banner(.init(state: s.state, added: tally.added, removed: tally.removed,
                                        fileVanished: s.fileVanished, machineName: s.record.machineName,
                                        nudging: Date() < nudgeUntil, undo: undo, redo: redo,
                                        alsoChanged: nearby,
                                        asksBeforeEditing: SessionPlan.asksBeforeEditing(s.record.filePath)))
    }

    // MARK: - starting

    private func buttonClicked(skipAsking: Bool) {
        guard let doc = document, doc.fileURL != nil, starting == nil else { return }
        if let s = session(for: doc), s.isLive {
            showTerminal()
            return
        }
        guard !wc.fileVanished else { return }
        wc.editor.bridge.selection { [weak self] anchor, head in
            guard let self, self.document === doc else { return }
            let lines = SessionPlan.selectedLines(in: self.wc.editor.bridge.text, anchor: anchor, head: head)
            if skipAsking {
                self.begin(doc, lines: lines, request: "")
            } else {
                self.ask(doc, lines: lines)
            }
        }
    }

    private func ask(_ doc: CrookDocument, lines: ClosedRange<Int>?) {
        guard let url = doc.fileURL else { return }
        popover?.close()
        let crumbs = Workspace.shared.breadcrumb(for: url)
        let defaults = UserDefaults.standard
        let context = AskPopover.Context(
            breadcrumb: crumbs.count > 1 ? crumbs.joined(separator: " ▸ ") : url.lastPathComponent,
            selectedLines: lines,
            machineName: doc.remoteProviderID == nil ? nil : Providers.current.displayName,
            showTip: lines == nil && defaults.integer(forKey: Self.startedCountKey) < 3,
            showFirstTime: !defaults.bool(forKey: Self.startedOnceKey),
            draft: drafts[url.path] ?? "",
            asksBeforeEditing: SessionPlan.asksBeforeEditing(url.path))
        let question = AskPopover(context: context)
        question.onDraftChange = { [weak self] text in self?.drafts[url.path] = text }
        question.onOpen = { [weak self] request in
            guard let self else { return }
            // The draft stays until a session has run: a check that fails, or
            // Claude Code closing at the trust question, sends the person back
            // here to try again with it.
            self.popover?.close()
            self.begin(doc, lines: lines, request: request)
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = question
        p.delegate = self
        p.show(relativeTo: accessory.anchor.bounds, of: accessory.anchor, preferredEdge: .minY)
        popover = p
    }

    func popoverDidClose(_ notification: Notification) {
        // A popover closed to make way for a new one reports after the new
        // one is showing.
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
    }

    /// The checks, in the order the spec gives them, stopping at the first that
    /// fails. The editor is read-only from here on, so nothing typed now can
    /// race the save Claude is about to read.
    private func begin(_ doc: CrookDocument, lines: ClosedRange<Int>?, request: String) {
        guard let url = doc.fileURL, starting == nil else { return }
        let provider = Providers.current
        guard providerID(of: doc) == provider.id else { return }
        popover?.close()
        wc.editor.dismissDiff()
        starting = url
        refresh()

        // 1. The file is still there.
        guard !wc.fileVanished, provider.exists(url.path) else {
            return fail(SessionCopy.vanished(fileName: url.lastPathComponent))
        }
        // 2. No conflict, or the person has chosen a version.
        resolveConflict(doc) { [weak self] proceed in
            guard let self else { return }
            guard proceed, self.document === doc else { return self.stopStarting() }
            // 3. The disk holds what the buffer holds. A failed save has already said why.
            guard doc.saveBeforeSession() else { return self.stopStarting() }
            self.wc.markEngaged()
            // 4. The machine is reachable.
            if !provider.isLocal && !provider.isConnected {
                return self.fail(SessionCopy.notConnected(machine: provider.displayName)) { [weak self] in
                    self?.wc.reconnect(to: provider.displayName)
                }
            }
            // 5. Claude Code is there, and new enough.
            let remote = provider as? RemoteProvider
            DispatchQueue.global(qos: .userInitiated).async {
                let result: ClaudePreflight.Result?
                if let remote {
                    result = ClaudePreflight.checkRemote(remote.transport)
                } else {
                    result = ClaudePreflight.checkLocal()
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.starting == url, self.document === doc else { return self.stopStarting() }
                    let machine = provider.isLocal ? nil : provider.displayName
                    switch result {
                    case .ready(let path, _)?:
                        self.launch(doc, url: url, provider: provider, claudePath: path, lines: lines, request: request)
                    case .missing?:
                        self.fail(SessionCopy.missing(machine: machine)) {
                            NSWorkspace.shared.open(SessionCopy.installURL)
                        }
                    case .tooOld(let version)?:
                        self.fail(SessionCopy.tooOld(machine: machine, installed: version)) { [weak self] in
                            self?.updateInTerminal(remote)
                        }
                    case nil:
                        self.fail(SessionCopy.notConnected(machine: provider.displayName)) { [weak self] in
                            self?.wc.reconnect(to: provider.displayName)
                        }
                    }
                }
            }
        }
    }

    private func stopStarting() {
        starting = nil
        refresh()
    }

    private func fail(_ alert: SessionCopy.Alert, onPrimary: (() -> Void)? = nil) {
        stopStarting()
        present(alert, onPrimary: onPrimary)
    }

    /// The disk changed while there were unsaved edits. Claude has to work on
    /// one version, and only the person can say which.
    private func resolveConflict(_ doc: CrookDocument, then done: @escaping (Bool) -> Void) {
        guard wc.hasConflict || doc.diskChangedUnderEdits(), let url = doc.fileURL else { return done(true) }
        let copy = SessionCopy.conflict(fileName: url.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        copy.buttons.forEach { alert.addButton(withTitle: $0) }
        let decide: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return done(false) }
            switch response {
            case .alertFirstButtonReturn:
                done(true)   // saveBeforeSession writes the buffer over the disk copy
            case .alertSecondButtonReturn:
                doc.reloadFromDiskDiscardingEdits(nil)
                // A reload that could not read the disk leaves the edits in
                // place, and the save that follows would then overwrite the
                // very version the person chose to keep.
                guard !doc.isDocumentEdited else {
                    self.present(SessionCopy.couldNotReadDisk(fileName: url.lastPathComponent))
                    return done(false)
                }
                done(true)
            default:
                done(false)
            }
        }
        if let w = wc.window { alert.beginSheetModal(for: w, completionHandler: decide) } else { decide(alert.runModal()) }
    }

    private func launch(_ doc: CrookDocument, url: URL, provider: FileProvider, claudePath: String,
                        lines: ClosedRange<Int>?, request: String) {
        guard let baseline = provider.contents(url.path) else {
            return fail(SessionCopy.vanished(fileName: url.lastPathComponent))
        }
        let roots = provider.isLocal
            ? Workspace.shared.importedURLs().map(\.path)
            : Workspace.importedPaths(forProviderID: provider.id)
        let machine = provider.isLocal ? nil : provider.displayName
        let id = UUID()
        let plan = SessionPlan.make(.init(filePath: url.path, projectRoots: roots, home: provider.homePath,
                                          machineName: machine, selectedLines: lines, request: request,
                                          voiceOver: NSWorkspace.shared.isVoiceOverEnabled, sessionID: id))

        // A new session supersedes a finished one's banner for the same file.
        for old in registry.sessions.filter({ !$0.isLive && $0.record.filePath == url.path
                                               && $0.record.providerID == provider.id }) {
            registry.discard(old)
        }
        let session: ClaudeSession
        do {
            session = try registry.begin(id: id, filePath: url.path, providerID: provider.id, machineName: machine,
                                         workingDirectory: plan.workingDirectory, baseline: baseline)
        } catch {
            return fail(SessionCopy.couldNotOpen(error.localizedDescription))
        }
        session.record.fingerprintsAtStart = fingerprints(under: plan.workingDirectory, excluding: url.path)

        let command: TerminalLauncher.Command
        if let remote = provider as? RemoteProvider {
            command = .remote(host: remote.transport.host, workingDirectory: plan.workingDirectory)
        } else {
            command = .local(workingDirectory: plan.workingDirectory, claudePath: claudePath)
        }

        arrangeWindow { [weak self] placement in
            guard let self else { return }
            session.record.crookFrameBefore = self.wc.window?.frame
            do {
                try TerminalLauncher.prepare(folder: session.folder, command: command,
                                             claudeArguments: plan.arguments, frame: placement?.terminal,
                                             bundleID: Bundle.main.bundleIdentifier)
            } catch {
                self.registry.discard(session)
                return self.fail(SessionCopy.couldNotOpen(error.localizedDescription))
            }
            self.placements[session.id] = placement
            self.registry.save(session)
            self.starting = nil
            self.registry.watch(session)
            self.refresh()
            self.wc.rail.reload()
            TerminalLauncher.open(folder: session.folder) { [weak self] error in
                guard let self, let error else { return }
                // Launch Services can report an error after Terminal ran the
                // command anyway. A runner that reported in is a session.
                guard session.state == .opening,
                      !FileManager.default.fileExists(atPath: session.file("runner.pid").path) else { return }
                self.registry.discard(session)
                self.refresh()
                self.present(SessionCopy.couldNotOpen(error.localizedDescription))
            }
        }
    }

    /// Leave full screen if Crook is in it — Terminal would open on another
    /// Space — then work out where Terminal goes.
    private func arrangeWindow(_ done: @escaping (TerminalLauncher.Placement?) -> Void) {
        guard let window = wc.window else { return done(nil) }
        guard window.styleMask.contains(.fullScreen) else { return done(placement()) }
        var observer: NSObjectProtocol?
        var finished = false
        let finish: () -> Void = { [weak self] in
            guard !finished else { return }
            finished = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            done(self?.placement())
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                          object: window, queue: .main) { _ in finish() }
        window.toggleFullScreen(nil)
        // If that notification never arrives, carry on rather than wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
    }

    private func placement() -> TerminalLauncher.Placement? {
        guard let window = wc.window, let screen = window.screen ?? NSScreen.main else { return nil }
        return TerminalLauncher.placement(crook: window.frame, visible: screen.visibleFrame,
                                          crookMinWidth: window.minSize.width)
    }

    // MARK: - while it runs

    private func sessionChanged(_ s: ClaudeSession) {
        #if CROOK_E2E
        defer { e2eSessionChanged(s) }
        #endif
        switch s.state {
        case .running where !s.handledStart:
            s.handledStart = true
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: Self.startedOnceKey)
            defaults.set(defaults.integer(forKey: Self.startedCountKey) + 1, forKey: Self.startedCountKey)
            if let p = placements[s.id], let crook = p.crook {
                makeRoom(for: s, crook: crook, terminal: p.terminal)
            }
            announce(SessionCopy.startedAnnouncement)
        case .ended(let outcome):
            placements[s.id] = nil
            ended(s, outcome: outcome)
        default:
            break
        }
        refresh()
        wc.rail.reload()
    }

    /// Move Crook aside only once Terminal is where it was asked to be. If it
    /// landed somewhere else, a narrowed Crook would be worse than overlap.
    private func makeRoom(for s: ClaudeSession, crook: CGRect, terminal: CGRect, attempts: Int = 15) {
        guard s.isLive else { return }
        let windowFile = s.file("window")
        guard let text = try? String(contentsOf: windowFile, encoding: .utf8) else {
            // The runner writes this a moment after it reports in.
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.makeRoom(for: s, crook: crook, terminal: terminal, attempts: attempts - 1)
            }
            return
        }
        // Empty: Terminal wouldn't say which window, so neither window moves.
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        confirmPlaced(s, window: number, crook: crook, terminal: terminal, checks: 4)
    }

    /// The runner places Terminal twice, a second apart, because Terminal still
    /// moves a brand-new window in that first moment. Look a few times before
    /// deciding it didn't land.
    private func confirmPlaced(_ s: ClaudeSession, window number: Int, crook: CGRect, terminal: CGRect, checks: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, s.isLive, let window = self.wc.window else { return }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            guard TerminalLauncher.landed(TerminalLauncher.frameOfWindow(number: number), near: terminal,
                                          primaryHeight: primaryHeight) else {
                if checks > 1 { self.confirmPlaced(s, window: number, crook: crook, terminal: terminal, checks: checks - 1) }
                return
            }
            window.setFrame(crook, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            s.record.crookFrameSet = window.frame
            self.registry.save(s)
        }
    }

    /// A write landed in the open file. True when the file is in watch mode and
    /// this has taken over highlighting it.
    func changeLanded(url: URL, before: String, after: String, disk: Data) -> Bool {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc), s.isLive else { return false }
        s.fileVanished = false
        let lines = SessionReview.changedLines(before: before, after: after)
        #if CROOK_E2E
        e2eChanged(lines)
        #endif
        if !lines.isEmpty {
            wc.editor.bridge.pushChangedLines(lines)
            wc.editor.bridge.reveal(lines: lines)
            announce(SessionCopy.changedAnnouncement(lines))
        }
        // Claude's version as it landed, byte for byte, so Undo still has
        // something true to offer if the session ends where Crook cannot read
        // the disk — a lost connection, or Crook closed. Replace checks the
        // disk still holds it.
        try? disk.write(to: s.file("final"), options: .atomic)
        refresh()
        return true
    }

    func fileVanished(_ url: URL) {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc), s.isLive, !s.fileVanished else { return }
        s.fileVanished = true
        refresh()
    }

    /// The file is back where it was, perhaps with the same bytes.
    func fileReturned(_ url: URL) {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc), s.fileVanished else { return }
        s.fileVanished = false
        refresh()
    }

    /// Whether Claude has this document's file right now.
    func isEditing(_ doc: CrookDocument) -> Bool {
        session(for: doc)?.isLive == true
    }

    /// Someone tried to type while Claude has the file. Say why nothing
    /// happened, for four seconds, drawing the eye once.
    private func nudge() {
        guard let doc = document, session(for: doc)?.isLive == true else { return }
        if Date() >= nudgeUntil {
            wc.editor.pulseBanner()
            announce(SessionCopy.nudgeAnnouncement)
        }
        nudgeUntil = Date().addingTimeInterval(4)
        refresh()
        nudgeEnds?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        nudgeEnds = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.05, execute: work)
    }

    private func showTerminal() {
        NSRunningApplication.runningApplications(withBundleIdentifier: TerminalLauncher.terminalBundleID)
            .first?.activate()
    }

    // MARK: - when it ends

    private func ended(_ s: ClaudeSession, outcome: SessionRunner.Outcome) {
        restoreFrame(s)
        let url = URL(fileURLWithPath: s.record.filePath)
        let providerID = s.record.providerID

        let protected = s.isRemote ? nil : SessionReview.protectedFolder(for: s.record.workingDirectory, home: Paths.home)
        if let alert = SessionCopy.alert(for: outcome, machine: s.record.machineName, protectedFolder: protected) {
            // The runner closes its Terminal window after it exits, reading
            // the script to do it from this folder; give it a moment.
            registry.discard(s, deletingFolderAfter: 10)
            // A failure from before Crook last quit is not news worth a sheet.
            guard !s.endedWhileAway else { return }
            present(alert) { [weak self] in
                switch outcome {
                case .claudeMissing: NSWorkspace.shared.open(SessionCopy.installURL)
                case .folderAccess: NSWorkspace.shared.open(SessionCopy.privacyURL)
                case .closedWithoutChanges, .didNotStart: self?.tryAgain(url, providerID: providerID)
                default: break
                }
            }
            return
        }
        // A session that ran: its request has been made.
        drafts[s.record.filePath] = nil

        // A file on this Mac can always be read, whichever machine the window
        // is looking at now.
        if let provider = Self.provider(for: s) {
            if let bytes = provider.contents(s.record.filePath) {
                s.fileVanished = false
                // Only a session Crook watched end can say this is Claude's
                // version. One that ended while Crook was closed may have been
                // edited since; its last-seen version, if any, stays as it was.
                if !s.endedWhileAway { try? bytes.write(to: s.file("final"), options: .atomic) }
            } else {
                s.fileVanished = true
            }
            // The sidebar and the files near this one are the window's machine's.
            if Providers.current.id == providerID {
                wc.rail.reload()
                s.record.alsoChanged = changedNearby(s)
            }
        }
        registry.save(s)

        if !s.endedWhileAway, let doc = document, doc.fileURL == url, self.providerID(of: doc) == providerID {
            let base = s.baseline.flatMap { try? ByteCodec.decode($0).0 as String } ?? ""
            let t = SessionReview.tally(baseline: base, current: doc.currentText())
            announce(SessionCopy.endedAnnouncement(added: t.added, removed: t.removed))
        }
    }

    /// Back to the popover, with the request typed before and the lines
    /// selected now.
    private func tryAgain(_ url: URL, providerID: String) {
        guard let doc = document, doc.fileURL == url, self.providerID(of: doc) == providerID else { return }
        buttonClicked(skipAsking: false)
    }

    /// Put Crook back, if it moved for Terminal and nobody has moved it since.
    /// After a restart Crook has re-centred its own window, so there only its
    /// size can say whether the person changed it.
    private func restoreFrame(_ s: ClaudeSession) {
        guard let set = s.record.crookFrameSet, let before = s.record.crookFrameBefore,
              let window = wc.window else { return }
        let sameSize = abs(window.frame.width - set.width) < 2 && abs(window.frame.height - set.height) < 2
        guard Self.roughlyEqual(window.frame, set) || (s.reattached && sameSize) else { return }
        // Not onto a display that has since gone: most of the old frame must
        // still be on a screen.
        let area = before.width * before.height
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(before)
            return !overlap.isNull && overlap.width * overlap.height >= area * 0.5
        }
        guard visible else { s.record.crookFrameSet = nil; return }
        window.setFrame(before, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        s.record.crookFrameSet = nil
    }

    private static func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
            && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private func bannerAction(_ action: BannerContent.Action) {
        guard let doc = document, let s = session(for: doc) else { return }
        switch action {
        case .showTerminal: showTerminal()
        case .endSession: registry.requestEnd(s)
        case .review: wc.showChanges(nil)
        case .undo: swapVersions(s, doc: doc, restoring: true)
        case .redo: swapVersions(s, doc: doc, restoring: false)
        case .done:
            registry.discard(s)
            refresh()
        }
        // The button pressed may be gone now. Keyboard focus goes to the text,
        // not to the window.
        if action != .showTerminal && action != .review { wc.editor.focusEditor() }
    }

    /// Undo puts the baseline back; Redo puts Claude's version back — each only
    /// if the disk still holds exactly the version it replaces.
    private func swapVersions(_ s: ClaudeSession, doc: CrookDocument, restoring: Bool) {
        guard let outcome = s.outcome, let provider = Self.provider(for: s),
              let baseline = s.baseline, let final = s.finalBytes else { return refresh() }
        let (expected, replacement) = restoring ? (final, baseline) : (baseline, final)
        do {
            guard try SessionReview.replace(path: s.record.filePath, on: provider,
                                            expecting: expected, with: replacement) else {
                refresh()
                return present(SessionCopy.swapRefused(fileName: URL(fileURLWithPath: s.record.filePath).lastPathComponent,
                                                        restoring: restoring))
            }
        } catch {
            wc.presentError(error)
            return
        }
        doc.reloadFromDisk()
        s.state = restoring ? .restored(outcome) : .ended(outcome)
        s.record.restored = restoring
        registry.save(s)
        refresh()
    }

    /// The person typed in a file. A finished session's banner has done its job.
    func userEdited(_ url: URL?) {
        guard let url, let doc = document, doc.fileURL == url,
              let s = session(for: doc), !s.isLive else { return }
        registry.discard(s)
        refresh()
    }

    /// What ⌘D compares against while a file has a session: everything Claude
    /// changed since it began, not since the file was last opened.
    func reviewBaseline(for url: URL) -> (text: String, title: String)? {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc),
              let data = s.baseline, let text = try? ByteCodec.decode(data).0 as String else { return nil }
        return (text, "Changes Claude made to \(url.lastPathComponent)")
    }

    // MARK: - menus

    func menuEditWithClaude() { buttonClicked(skipAsking: false) }
    func menuEditWithClaudeNow() { buttonClicked(skipAsking: true) }

    func menuEndSession() {
        guard let doc = document, let s = session(for: doc), s.state == .running else { return }
        registry.requestEnd(s)
    }

    func validate(_ item: NSMenuItem) -> Bool {
        let hasFile = document?.fileURL != nil
        let s = document.flatMap { session(for: $0) }
        let live = s?.isLive == true
        switch item.action {
        case #selector(WorkspaceWindowController.editWithClaude(_:)):
            item.title = live ? "Show Claude Session" : "Edit with Claude…"
            return hasFile && starting == nil && (live || !wc.fileVanished)
        case #selector(WorkspaceWindowController.editWithClaudeNow(_:)):
            return hasFile && starting == nil && !live && !wc.fileVanished
        case #selector(WorkspaceWindowController.endClaudeSession(_:)):
            // Only there while a session is.
            item.isHidden = !live
            return s?.state == .running
        default:
            return true
        }
    }

    // MARK: - helpers

    @objc private func windowResized() {
        accessory.setCompact((wc.window?.frame.width ?? 1000) < 900)
    }

    private func present(_ alert: SessionCopy.Alert, onPrimary: (() -> Void)? = nil) {
        let a = NSAlert()
        a.messageText = alert.title
        a.informativeText = alert.message
        alert.buttons.forEach { a.addButton(withTitle: $0) }
        // Esc answers OK, as it would Cancel.
        if a.buttons.count > 1, let last = a.buttons.last, last.title == "OK" { last.keyEquivalent = "\u{1b}" }
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn, alert.buttons.count > 1 { onPrimary?() }
        }
        if let w = wc.window, w.isVisible { a.beginSheetModal(for: w, completionHandler: handle) }
        else { handle(a.runModal()) }
    }

    private func announce(_ text: String) {
        guard !text.isEmpty, let window = wc.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func fingerprints(under folder: String, excluding path: String) -> [String: String] {
        let provider = Providers.current
        var out: [String: String] = [:]
        for file in Workspace.shared.filePaths(under: folder) where file != path {
            if let f = provider.fingerprint(file) { out[file] = "\(f.mtime):\(f.size)" }
        }
        return out
    }

    private func changedNearby(_ s: ClaudeSession) -> [String] {
        let now = fingerprints(under: s.record.workingDirectory, excluding: s.record.filePath)
        let before = s.record.fingerprintsAtStart
        return Set(now.keys).union(before.keys).filter { now[$0] != before[$0] }.sorted()
    }

    private func openNearby(_ relative: String, from s: ClaudeSession) {
        let path = (s.record.workingDirectory as NSString).appendingPathComponent(relative)
        wc.retarget(to: URL(fileURLWithPath: path))
    }

    /// Whether a session's file no longer holds its baseline. Unknown — the
    /// window looking at another machine — counts as changed, so the ending is
    /// a banner to review rather than an alert that might be wrong.
    private static func differsFromBaseline(_ s: ClaudeSession) -> Bool {
        guard let provider = provider(for: s), let baseline = s.baseline,
              let now = provider.contents(s.record.filePath) else { return true }
        return now != baseline
    }

    /// Where a session's file can be read now: this Mac's always, another
    /// Mac's only while the window is connected to it.
    private static func provider(for s: ClaudeSession) -> FileProvider? {
        guard s.isRemote else { return Providers.local }
        let p = Providers.current
        return p.id == s.record.providerID && p.isConnected ? p : nil
    }

    /// `claude update`, in Terminal, on whichever Mac needs it. Not a session:
    /// nothing is watched, and the window stays open with the update's output.
    private func updateInTerminal(_ remote: RemoteProvider?) {
        let folder = registry.root.appendingPathComponent("update-\(UUID().uuidString.lowercased())", isDirectory: true)
        let home = remote?.homePath ?? Paths.home
        let command: TerminalLauncher.Command
        if let remote {
            command = .remote(host: remote.transport.host, workingDirectory: home)
        } else {
            let found = ClaudePreflight.knownLocations(home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
            command = .local(workingDirectory: home, claudePath: found ?? "claude")
        }
        do {
            try TerminalLauncher.prepare(folder: folder, command: command, claudeArguments: ["update"],
                                         frame: nil, bundleID: nil, includeWindowScript: false)
        } catch {
            return present(SessionCopy.couldNotOpen(error.localizedDescription))
        }
        ClaudePreflight.forgetCachedInstall()
        TerminalLauncher.open(folder: folder) { _ in }
    }
}

#if CROOK_E2E
// MARK: - end-to-end self-test

/// Built only with `CROOK_SWIFT_FLAGS="-D CROOK_E2E" ./scripts/build.sh`, so it
/// never ships.
///
/// `CROOK_E2E_CLAUDE="<request>"` with a file to open drives one real session:
/// the popover, the checks, Terminal, claude, the reload, then an ending
/// (`CROOK_E2E_END`: `session` for End Session, `exit` for the driver to type
/// /exit, `quit` to quit Crook mid-session), then Undo, Redo and Done. With
/// `CROOK_E2E_PHASE=reattach` it instead picks up a session left running by a
/// `quit` run and ends it. `CROOK_E2E_REOPEN=1` closes the window once the
/// session has ended and opens the file again before Undo.
/// `CROOK_E2E_SUSPEND=1` suspends the session as Ctrl-Z does before ending it.
/// `CROOK_E2E_MAXWAIT=<s>` ends it that long after starting even without a
/// change. `CROOK_E2E_TYPE_AFTER=1` types into the file after Done and watches
/// for autosave to complain. Every step is a
/// "Crook: E2E" log line; "E2E shot <name> <window ids>" asks the driver to
/// photograph those windows only.
private final class E2E {
    static let shared = E2E()
    let env = ProcessInfo.processInfo.environment
    var lastNote = ""
    var lastChange = Date.distantPast
    var changes = 0
    var session: ClaudeSession?
    var reviewed = false
    var watching = false
    var reopened = false
}

extension SessionController {

    private func e2e(_ message: String) { NSLog("Crook: E2E %@", message) }

    private var e2eOn: Bool { E2E.shared.env["CROOK_E2E_CLAUDE"] != nil }

    func e2eStart() {
        let e = E2E.shared
        guard let request = e.env["CROOK_E2E_CLAUDE"] else { return }
        let lines = e.env["CROOK_E2E_LINES"].flatMap { s -> ClosedRange<Int>? in
            let p = s.split(separator: "-").compactMap { Int($0) }
            return p.count == 2 && p[0] <= p[1] ? p[0]...p[1] : nil
        }
        e2eWhenDocumentReady(tries: 120) { [weak self] doc in
            guard let self else { return }
            if let f = e.env["CROOK_E2E_FRAME"]?.split(separator: " ").compactMap({ Double($0) }), f.count == 4 {
                self.wc.window?.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: true)
            }
            self.e2e("open \(doc.fileURL?.path ?? "?") phase=\(e.env["CROOK_E2E_PHASE"] ?? "full") frame=\(self.wc.window?.frame ?? .zero)")
            if e.env["CROOK_E2E_PHASE"] == "reattach" {
                guard let s = self.session(for: doc) else {
                    self.e2e("reattach no-session")
                    return NSApp.terminate(nil)
                }
                e.session = s
                self.e2e("reattach state=\(s.state) readOnly=\(s.isLive)")
                self.e2eShot("reattached")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.e2e("end-session")
                    self.registry.requestEnd(s)
                }
                return
            }
            self.e2eShot("idle")
            self.ask(doc, lines: lines)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.e2eShot("popover")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.popover?.close()
                    self.begin(doc, lines: lines, request: request)
                }
            }
        }
    }

    private func e2eWhenDocumentReady(tries: Int, _ go: @escaping (CrookDocument) -> Void) {
        if let doc = document, doc.fileURL != nil, wc.editor.bridge.isReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { go(doc) }
            return
        }
        guard tries > 0 else {
            e2e("no-document")
            return NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.e2eWhenDocumentReady(tries: tries - 1, go)
        }
    }

    private func e2eTerminalWindow() -> Int? {
        guard let s = E2E.shared.session,
              let t = try? String(contentsOf: s.file("window"), encoding: .utf8) else { return nil }
        return Int(t.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ask the driver to photograph Crook's window, and Terminal's if there is one.
    private func e2eShot(_ name: String) {
        var ids = [wc.window?.windowNumber ?? 0]
        if let t = e2eTerminalWindow() { ids.append(t) }
        e2e("shot \(name) \(ids.map(String.init).joined(separator: " "))")
    }

    private func e2eFrames(_ label: String) {
        var line = "frames \(label) crook=\(wc.window?.frame ?? .zero)"
        if let t = e2eTerminalWindow(), let cg = TerminalLauncher.frameOfWindow(number: t) {
            let h = NSScreen.screens.first?.frame.height ?? 0
            line += " terminal(appkit)=\(CGRect(x: cg.minX, y: h - cg.maxY, width: cg.width, height: cg.height))"
        }
        if let s = E2E.shared.session, let p = placements[s.id] {
            line += " planned-terminal=\(p.terminal) planned-crook=\(String(describing: p.crook))"
        }
        e2e(line)
    }

    func e2eNote() {
        guard e2eOn else { return }
        let doc = document
        let s = doc.flatMap { session(for: $0) }
        let content = doc.flatMap { d in s.flatMap { banner(for: $0, doc: d) } }
        let shown = content.map { "\($0.title) | \($0.note ?? "-") | \($0.buttons.map { $0.enabled ? $0.title : "(\($0.title))" })" } ?? "none"
        let note = "state=\(s.map { "\($0.state)" } ?? "none") starting=\(starting != nil) button=\(accessory.mode) "
            + "buttonWidth=\(Int(accessory.view.frame.width)) banner=\(shown)"
        guard note != E2E.shared.lastNote else { return }
        E2E.shared.lastNote = note
        e2e("note \(note)")
    }

    func e2eChanged(_ lines: [Int]) {
        guard e2eOn else { return }
        E2E.shared.changes += 1
        E2E.shared.lastChange = Date()
        let buttons = wc.editor.e2eBannerButtons
        let scroller = "document.querySelector('.cm-scroller')"
        let js = "(() => { const s = \(scroller); const box = s.getBoundingClientRect();"
            + " const lit = [...document.querySelectorAll('.q-changed')].filter(l => { const r = l.getBoundingClientRect();"
            + " return r.top >= box.top && r.bottom <= box.bottom }).length;"
            + " return s.scrollTop + ' litVisible=' + lit })()"
        wc.editor.bridge.webView?.evaluateJavaScript(js) { [weak self] before, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let self else { return }
                self.wc.editor.bridge.webView?.evaluateJavaScript(js) { after, _ in
                    let now = self.wc.editor.e2eBannerButtons
                    self.e2e("change lines=\(lines) scrollTop \(before ?? "?") -> \(after ?? "?") "
                             + "sameBannerButtons=\(!buttons.isEmpty && buttons == now)")
                }
            }
        }
    }

    func e2eSessionChanged(_ s: ClaudeSession) {
        let e = E2E.shared
        guard e2eOn else { return }
        e.session = s
        e2e("session state=\(s.state) folder=\(s.folder.path)")
        switch s.state {
        case .running where e.env["CROOK_E2E_PHASE"] != "reattach" && !e.watching:
            e.watching = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.e2eFrames("running")
                self.e2eShot("running")
                self.e2eTypeWhileReadOnly()
            }
            e2eWaitForQuiet()
        case .ended(let outcome):
            guard !e.reviewed else { return }
            e.reviewed = true
            e2e("ended outcome=\(outcome)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.e2eReview(s) }
        default:
            break
        }
    }

    /// Put text into the editor the ways a person could, and check none of it
    /// reached the buffer.
    private func e2eTypeWhileReadOnly() {
        guard let wv = wc.editor.bridge.webView else { return }
        let js = """
        (() => {
          const c = document.querySelector('.cm-content');
          c.focus();
          c.dispatchEvent(new KeyboardEvent('keydown', {key: 'x', bubbles: true, cancelable: true}));
          document.execCommand('insertText', false, 'TYPED-WHILE-READONLY');
          return c.innerText.includes('TYPED-WHILE-READONLY');
        })()
        """
        wv.evaluateJavaScript(js) { [weak self] value, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let self else { return }
                let buffer = self.wc.editor.bridge.text as String
                self.e2e("typed-while-readonly domShowsIt=\(String(describing: value)) bufferHasIt=\(buffer.contains("TYPED-WHILE-READONLY")) nudging=\(Date() < self.nudgeUntil) error=\(String(describing: error))")
                self.e2eShot("nudge")
            }
        }
    }

    private func e2eState(_ pid: Int32) -> String {
        guard pid > 0 else { return "none" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "state=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "gone" : s
    }

    /// Type after the session, as a person would, and watch for AppKit's
    /// "changed by another application" sheet when autosave runs.
    private func e2eTypeAndWatchAutosave(path: String) {
        wc.editor.bridge.e2eType("TYPED-AFTER ")
        do {
            var checks = 0
            func look() {
                checks += 1
                let doc = self.wc.document as? CrookDocument
                let disk = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
                self.e2e("typed-after t=\(checks * 10)s sheet=\(self.wc.window?.attachedSheet != nil) edited=\(doc?.isDocumentEdited == true) diskHasIt=\(disk.contains("TYPED-AFTER"))")
                if self.wc.window?.attachedSheet != nil { self.e2eShot("autosave-sheet") }
                if checks < 6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { look() }
                } else {
                    self.e2e("finished")
                    NSApp.terminate(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { look() }
        }
    }

    private func e2eWaitForQuiet() {
        let e = E2E.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let s = e.session, s.isLive else { return }
            let quietFor = Double(e.env["CROOK_E2E_QUIET"] ?? "") ?? 15
            let quiet = e.changes > 0 && Date().timeIntervalSince(e.lastChange) > quietFor
            let tooLong = Date().timeIntervalSince(s.record.startedAt) > (Double(e.env["CROOK_E2E_MAXWAIT"] ?? "") ?? 300)
            guard quiet || tooLong else { return self.e2eWaitForQuiet() }
            if tooLong { self.e2e("timeout-waiting-for-changes") }
            self.e2eFrames("changed")
            self.e2eShot("changed")
            if e.env["CROOK_E2E_SUSPEND"] != nil, let runner = s.record.runnerPID {
                // What Ctrl-Z in Claude Code does to Terminal's job.
                killpg(getpgid(runner), SIGTSTP)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let child = SessionRegistry.readPID(s.file("child.pid")) ?? 0
                    self.e2e("suspended runner=\(self.e2eState(runner)) child=\(self.e2eState(child))")
                    self.e2eShot("suspended")
                    self.e2e("end-session")
                    self.registry.requestEnd(s)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                switch e.env["CROOK_E2E_END"] ?? "session" {
                case "exit":
                    self.e2e("send-exit \(self.e2eTerminalWindow() ?? 0)")
                case "quit":
                    self.e2e("quitting-mid-session")
                    NSApp.terminate(nil)
                default:
                    self.e2e("end-session")
                    self.registry.requestEnd(s)
                }
            }
        }
    }

    private func e2eReview(_ s: ClaudeSession) {
        guard document != nil else {
            e2e("review no-document")
            return NSApp.terminate(nil)
        }
        let path = s.record.filePath
        let provider = Providers.current
        e2eFrames("ended")
        e2eShot("ended")
        e2e("terminal-window-still-open=\(e2eTerminalWindow().flatMap { TerminalLauncher.frameOfWindow(number: $0) } != nil)")
        guard E2E.shared.env["CROOK_E2E_REOPEN"] == nil || E2E.shared.reopened else {
            E2E.shared.reopened = true
            wc.window?.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.e2e("closed-window visible=\(self.wc.window?.isVisible == true) showing=\(self.document != nil) button=\(self.accessory.mode)")
                self.wc.showWindow(nil)
                self.wc.retarget(to: URL(fileURLWithPath: s.record.filePath))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.e2e("reopened showing=\(self.document != nil)")
                    self.e2eShot("reopened")
                    self.e2eReview(s)
                }
            }
            return
        }
        let final = s.finalBytes
        bannerAction(.undo)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.e2e("undo diskIsBaseline=\(provider.contents(path) == s.baseline) bufferIsBaseline=\((try? self.wc.editor.bridge.data()) == s.baseline)")
            self.e2eShot("undone")
            self.bannerAction(.redo)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.e2e("redo diskIsFinal=\(final != nil && provider.contents(path) == final)")
                let folder = s.folder
                self.bannerAction(.done)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.e2e("done folderRemoved=\(!FileManager.default.fileExists(atPath: folder.path))")
                    self.e2eShot("done")
                    guard E2E.shared.env["CROOK_E2E_TYPE_AFTER"] != nil else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.e2e("finished")
                            NSApp.terminate(nil)
                        }
                        return
                    }
                    self.e2eTypeAndWatchAutosave(path: path)
                }
            }
        }
    }
}
#endif
