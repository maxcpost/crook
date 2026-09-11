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
    }

    // MARK: - the open file

    private var document: CrookDocument? { wc.document as? CrookDocument }

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
        let provider = Providers.current
        let connected = provider.id == s.record.providerID && provider.isConnected
        // What is on screen, as bytes, when nothing is unsaved. Undo and Redo
        // are offered only while it is exactly the version they replace.
        let onScreen = doc.isDocumentEdited ? nil : try? wc.editor.bridge.data()
        let undo = SessionCopy.swapAvailability(verb: "undo", fileVanished: s.fileVanished, connected: connected,
                                                machine: s.record.machineName,
                                                diskMatches: onScreen != nil && onScreen == s.finalBytes)
        let redo = SessionCopy.swapAvailability(verb: "redo", fileVanished: s.fileVanished, connected: connected,
                                                machine: s.record.machineName,
                                                diskMatches: onScreen != nil && onScreen == s.baseline)
        let nearby = s.record.alsoChanged.map { SessionPlan.relativePath($0, from: s.record.workingDirectory) }
        return SessionCopy.banner(.init(state: s.state, added: tally.added, removed: tally.removed,
                                        fileVanished: s.fileVanished, machineName: s.record.machineName,
                                        nudging: Date() < nudgeUntil, undo: undo, redo: redo,
                                        alsoChanged: nearby))
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
            draft: drafts[url.path] ?? "")
        let question = AskPopover(context: context)
        question.onDraftChange = { [weak self] text in self?.drafts[url.path] = text }
        question.onOpen = { [weak self] request in
            guard let self else { return }
            self.drafts[url.path] = nil
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
        popover = nil
    }

    /// The checks, in the order the spec gives them, stopping at the first that
    /// fails. The editor is read-only from here on, so nothing typed now can
    /// race the save Claude is about to read.
    private func begin(_ doc: CrookDocument, lines: ClosedRange<Int>?, request: String) {
        guard let url = doc.fileURL, starting == nil else { return }
        let provider = Providers.current
        guard providerID(of: doc) == provider.id else { return }
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
        guard wc.hasConflict, let url = doc.fileURL else { return done(true) }
        let copy = SessionCopy.conflict(fileName: url.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        copy.buttons.forEach { alert.addButton(withTitle: $0) }
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                done(true)   // saveBeforeSession writes the buffer over the disk copy
            case .alertSecondButtonReturn:
                doc.reloadFromDiskDiscardingEdits(nil)
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
                                             claudeArguments: plan.arguments, bounds: placement?.terminal,
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
        guard let window = wc.window, let screen = window.screen ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return nil }
        return TerminalLauncher.placement(crook: window.frame, visible: screen.visibleFrame,
                                          primaryHeight: primary.frame.height,
                                          crookMinWidth: window.minSize.width)
    }

    // MARK: - while it runs

    private func sessionChanged(_ s: ClaudeSession) {
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
        guard s.isLive, let window = wc.window else { return }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, s.isLive,
                  TerminalLauncher.landed(TerminalLauncher.frameOfWindow(number: number), near: terminal) else { return }
            window.setFrame(crook, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            s.record.crookFrameSet = window.frame
            self.registry.save(s)
        }
    }

    /// A write landed in the open file. True when the file is in watch mode and
    /// this has taken over highlighting it.
    func changeLanded(url: URL, before: String, after: String) -> Bool {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc), s.isLive else { return false }
        s.fileVanished = false
        let lines = SessionReview.changedLines(before: before, after: after)
        if let first = lines.first {
            wc.editor.bridge.pushChangedLines(lines)
            wc.editor.bridge.revealLine(first)
            announce(SessionCopy.changedAnnouncement(lines))
        }
        refresh()
        return true
    }

    func fileVanished(_ url: URL) {
        guard let doc = document, doc.fileURL == url, let s = session(for: doc), s.isLive else { return }
        s.fileVanished = true
        refresh()
    }

    /// Someone tried to type while Claude has the file. Say why nothing
    /// happened, for four seconds, drawing the eye once.
    private func nudge() {
        guard let doc = document, session(for: doc)?.isLive == true else { return }
        if Date() >= nudgeUntil { wc.editor.pulseBanner() }
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
        let provider = Providers.current
        let here = provider.id == s.record.providerID
        let url = URL(fileURLWithPath: s.record.filePath)

        let protected = s.isRemote ? nil : SessionReview.protectedFolder(for: s.record.workingDirectory, home: Paths.home)
        if let alert = SessionCopy.alert(for: outcome, machine: s.record.machineName, protectedFolder: protected) {
            registry.discard(s)
            // A failure from before Crook last quit is not news worth a sheet.
            guard !s.endedWhileAway else { return }
            present(alert) { [weak self] in
                switch outcome {
                case .claudeMissing: NSWorkspace.shared.open(SessionCopy.installURL)
                case .folderAccess: NSWorkspace.shared.open(SessionCopy.privacyURL)
                case .closedWithoutChanges: self?.tryAgain(url)
                default: break
                }
            }
            return
        }

        if here && provider.isConnected {
            if let bytes = provider.contents(s.record.filePath) {
                try? bytes.write(to: s.file("final"), options: .atomic)
            } else {
                s.fileVanished = true
            }
            wc.rail.reload()
            s.record.alsoChanged = changedNearby(s)
        }
        registry.save(s)

        // A window closed during the session comes back on this file.
        if document == nil, here, !s.fileVanished, !s.endedWhileAway {
            wc.retarget(to: url)
        }
        if !s.endedWhileAway, let doc = document, doc.fileURL == url {
            let base = s.baseline.flatMap { try? ByteCodec.decode($0).0 as String } ?? ""
            let t = SessionReview.tally(baseline: base, current: doc.currentText())
            announce(SessionCopy.endedAnnouncement(added: t.added, removed: t.removed))
        }
    }

    private func tryAgain(_ url: URL) {
        guard let doc = document, doc.fileURL == url else { return }
        ask(doc, lines: nil)
    }

    /// Put Crook back, if it moved for Terminal and nobody has moved it since.
    private func restoreFrame(_ s: ClaudeSession) {
        guard let set = s.record.crookFrameSet, let before = s.record.crookFrameBefore,
              let window = wc.window, Self.roughlyEqual(window.frame, set) else { return }
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
    }

    /// Undo puts the baseline back; Redo puts Claude's version back — each only
    /// if the disk still holds exactly the version it replaces.
    private func swapVersions(_ s: ClaudeSession, doc: CrookDocument, restoring: Bool) {
        let provider = Providers.current
        guard let outcome = s.outcome, provider.id == s.record.providerID, provider.isConnected,
              let baseline = s.baseline, let final = s.finalBytes else { return refresh() }
        let (expected, replacement) = restoring ? (final, baseline) : (baseline, final)
        do {
            guard try SessionReview.replace(path: s.record.filePath, on: provider,
                                            expecting: expected, with: replacement) else { return refresh() }
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
        let provider = Providers.current
        guard provider.id == s.record.providerID, let baseline = s.baseline,
              let now = provider.contents(s.record.filePath) else { return true }
        return now != baseline
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
                                         bounds: nil, bundleID: nil, includeWindowScript: false)
        } catch {
            return present(SessionCopy.couldNotOpen(error.localizedDescription))
        }
        ClaudePreflight.forgetCachedInstall()
        TerminalLauncher.open(folder: folder) { _ in }
    }
}
