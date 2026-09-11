import AppKit

/// The rail: two sections, SYSTEM over PROJECTS.
///
/// Supersedes D-15's flat-list-with-drill-in. The user asked for an IDE-style
/// tree with expandable projects, so this is an NSOutlineView — native
/// disclosure, native keyboard traversal, and the accessibility tree for free.
final class RailViewController: NSViewController {

    private var outline: NSOutlineView!
    private var scroll: NSScrollView!
    private var appearanceButton: NSButton!
    /// Which machine this window is looking at. Sits beside the appearance
    /// toggle rather than at the top: it is a property of the window, not a
    /// heading for the tree, and putting it above SYSTEM implied the tree was
    /// nested inside it.
    private var machineButton: NSPopUpButton!
    private let ws = Workspace.shared

    /// Section headers are Nodes too, so the outline has one uniform item type.
    private var roots: [Workspace.Node] = []

    /// Nodes are rebuilt on every reload, so expansion cannot be tracked by
    /// object identity. A URL is stable; a section has none, so it keys by name.
    private static func key(_ n: Workspace.Node) -> String {
        n.url?.path ?? "section:\(n.name)"
    }

    var onOpen: ((URL) -> Void)?
    var onConnect: (() -> Void)?
    var onUseLocal: (() -> Void)?
    var onSwitchTo: ((String) -> Void)?

    /// Rebuild the machine menu. A pull-down's first item is its label, so the
    /// title carries the current machine and the rest are somewhere to go.
    func setMachine(name: String?, connected: Bool) {
        guard machineButton != nil else { return }
        let menu = NSMenu()
        let title = name.map { connected ? $0 : "\($0) — offline" } ?? "This Mac"
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")

        if name != nil {
            let local = NSMenuItem(title: "This Mac", action: #selector(useLocal), keyEquivalent: "")
            local.target = self
            menu.addItem(local)
        }
        for host in Machines.shared.known where host != name {
            let item = NSMenuItem(title: host, action: #selector(switchMachine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = host
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let connect = NSMenuItem(title: "Connect to a Machine…", action: #selector(connectTapped), keyEquivalent: "")
        connect.target = self
        menu.addItem(connect)

        machineButton.menu = menu
        machineButton.contentTintColor = connected || name == nil ? .tertiaryLabelColor : .systemOrange
    }

    private func rail_reloadAfterAdd() { reload() }

    @objc private func useLocal() { onUseLocal?() }
    @objc private func connectTapped() { onConnect?() }
    @objc private func switchMachine(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        onSwitchTo?(host)
    }

    override func loadView() {
        // The rail supplies its own material and fills its pane edge to edge.
        //
        // NSSplitViewItem(sidebarWithViewController:) on macOS 26 wraps the view
        // in Liquid Glass inset 8pt, producing a floating rounded card. The
        // document pane next to it is flush and square to the window edge, so
        // the two panes are different shapes and meet in a visible seam at the
        // bottom corners. Flush is the arrangement Finder, Mail and Notes use:
        // one hairline divider, and the window does the rounding once.
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState
        view = container

        outline = NSOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.indentationPerLevel = 13
        outline.indentationMarkerFollowsCell = true
        outline.autosaveExpandedItems = false
        outline.floatsGroupRows = false
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 26
        outline.allowsMultipleSelection = false
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = []
        outline.backgroundColor = .clear
        outline.enclosingScrollView?.drawsBackground = false
        outline.intercellSpacing = NSSize(width: 0, height: 2)

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)

        scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        // Overlay scrollers appear on scroll and fade out. The legacy style
        // reserves a permanent track, which is the grey bar sitting in a list
        // that has nothing to scroll.
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        // automaticallyAdjustsContentInsets draws a 1px _NSLayerBasedFillColorView
        // separator across the top of the scroll view — the dark line above
        // SYSTEM. It exists to divide content scrolling under a titlebar, and
        // since the panes now sit below the chrome there is nothing to divide.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 14, right: 0)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        // Appearance, bottom-left. One borderless button cycling
        // System -> Light -> Dark, because three states do not need three
        // controls and a segmented control would be the loudest thing in the rail.
        appearanceButton = NSButton()
        appearanceButton.isBordered = false
        appearanceButton.bezelStyle = .inline
        appearanceButton.imagePosition = .imageOnly
        appearanceButton.target = self
        appearanceButton.action = #selector(cycleAppearance)
        appearanceButton.translatesAutoresizingMaskIntoConstraints = false
        appearanceButton.contentTintColor = .tertiaryLabelColor
        container.addSubview(appearanceButton)

        machineButton = NSPopUpButton(frame: .zero, pullsDown: true)
        machineButton.isBordered = false
        machineButton.font = .systemFont(ofSize: 11)
        machineButton.translatesAutoresizingMaskIntoConstraints = false
        machineButton.controlSize = .small
        container.addSubview(machineButton)

        NSLayoutConstraint.activate([
            machineButton.leadingAnchor.constraint(equalTo: appearanceButton.trailingAnchor, constant: 4),
            machineButton.centerYAnchor.constraint(equalTo: appearanceButton.centerYAnchor),
            machineButton.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: appearanceButton.topAnchor, constant: -4),

            appearanceButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            appearanceButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            appearanceButton.widthAnchor.constraint(equalToConstant: 22),
            appearanceButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Must run here, not only on click. Without it the button has no image
        // until the first cycle, which reads as a missing icon on every launch.
        syncAppearanceButton()
        // Breathing room beyond the titlebar, and clearance at the bottom so the
        // last row never sits on the glass edge.
        reload()
    }

    func reload() {
        // Opening a file rebuilds the tree, and a rebuild used to collapse
        // every folder the reader had opened — including the one holding the
        // file they just clicked, which snapped shut under the pointer.
        let wasExpanded = expandedKeys()
        let selectedKey = (outline.item(atRow: outline.selectedRow) as? Workspace.Node).map(Self.key)

        ws.reload()
        roots = ws.roots
        outline.reloadData()

        if wasExpanded.isEmpty {
            // First run only: sections open, plus skills. Auto-expanding every
            // SYSTEM child pushes PROJECTS below the fold.
            for section in roots { outline.expandItem(section) }
            if let system = roots.first(where: { $0.name == "SYSTEM" }) {
                for child in system.children where child.name == "skills" {
                    outline.expandItem(child)
                }
            }
        } else {
            restore(wasExpanded)
        }
        if let k = selectedKey { select(k) }
        if ProcessInfo.processInfo.environment["CROOK_TRACE_TREE"] != nil {
            NSLog("Crook: reload — expanded before=\(wasExpanded.count) after=\(expandedKeys().count)")
        }
    }

    /// Exercised by CROOK_TRACE_TREE: expand a few folders, reload the way
    /// opening a file does, and report whether the disclosure survived.
    func selfTestExpansion() {
        for row in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: row) as? Workspace.Node, n.isExpandable else { continue }
            outline.expandItem(n)
        }
        let before = expandedKeys().count
        reload()
        let after = expandedKeys().count
        NSLog("Crook: TREE SELF-TEST expanded=\(before) survived-reload=\(after) pass=\(after >= before)")
    }

    private func expandedKeys() -> Set<String> {
        var out = Set<String>()
        for row in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: row) as? Workspace.Node else { continue }
            if outline.isItemExpanded(n) { out.insert(Self.key(n)) }
        }
        return out
    }

    /// Expand top-down: a child cannot be expanded before its parent exists in
    /// the outline's row map.
    private func restore(_ keys: Set<String>) {
        func walk(_ nodes: [Workspace.Node]) {
            for n in nodes where n.isExpandable {
                if keys.contains(Self.key(n)) {
                    outline.expandItem(n)
                    walk(n.children)
                }
            }
        }
        walk(roots)
    }

    private func select(_ key: String) {
        for row in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: row) as? Workspace.Node else { continue }
            if Self.key(n) == key {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
    }

    /// Select the row for a file without disturbing anything else — used when a
    /// document opens, so the rail reflects what the editor is showing.
    func selectFile(_ url: URL) { select(url.path) }

    // MARK: - appearance

    private static let appearanceKey = "CrookAppearance"   // 0 system, 1 light, 2 dark

    private func syncAppearanceButton() {
        let mode = UserDefaults.standard.integer(forKey: Self.appearanceKey)
        let (symbol, help): (String, String) = switch mode {
        case 1: ("sun.max", "Light appearance — click for dark")
        case 2: ("moon", "Dark appearance — click to follow the system")
        default: ("circle.lefthalf.filled", "Following the system — click for light")
        }
        appearanceButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        appearanceButton.toolTip = help
        NSApp.appearance = switch mode {
        case 1: NSAppearance(named: .aqua)
        case 2: NSAppearance(named: .darkAqua)
        default: nil          // nil means follow the system
        }
    }

    @objc private func cycleAppearance() {
        let next = (UserDefaults.standard.integer(forKey: Self.appearanceKey) + 1) % 3
        UserDefaults.standard.set(next, forKey: Self.appearanceKey)
        syncAppearanceButton()
    }

    func beginAddProject() { addProject() }

    @objc private func addProject() {
        // A file panel can only browse a disk this Mac has. For another machine
        // the agent supplies the candidates instead.
        if !Providers.current.isLocal {
            let picker = RemoteProjectPicker()
            picker.onPick = { [weak self] urls in
                guard let self else { return }
                for u in urls { self.ws.addProject(u) }
                if let remote = Providers.current as? RemoteProvider {
                    // The new roots have to reach the agent before its tree can
                    // include them, and before its watch can see them change.
                    //
                    // From what is now persisted, not from this sheet's picks:
                    // addProject has already saved them, and declaring only
                    // `urls` un-declared every project added before this one.
                    remote.declareRoots(
                        Workspace.remoteRoots(home: remote.homePath, providerID: remote.id))
                    remote.refresh { self.rail_reloadAfterAdd() }
                    remote.startWatching()
                } else {
                    self.reload()
                }
            }
            presentAsSheet(picker)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a project that uses Claude Code."
        if let suggestion = ws.suggestions().first { panel.directoryURL = suggestion.deletingLastPathComponent() }
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            for url in panel.urls { self.ws.addProject(url) }
            self.reload()
        }
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Workspace.Node else { return }
        if node.kind == .action {
            addProject()
        } else if node.kind == .file, let url = node.url {
            onOpen?(url)
        } else if node.isExpandable {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        }
    }
}

extension RailViewController: NSOutlineViewDataSource {
    func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Workspace.Node else { return roots.count }
        return node.children.count
    }

    func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Workspace.Node else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Workspace.Node)?.isExpandable ?? false
    }
}

extension RailViewController: NSOutlineViewDelegate {

    func outlineView(_ v: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Workspace.Node)?.kind == .section
    }

    func outlineView(_ v: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let k = (item as? Workspace.Node)?.kind else { return false }
        return k != .section && k != .action
    }

    func outlineView(_ v: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Workspace.Node else { return nil }

        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = v.makeView(withIdentifier: id, owner: self) as? RailCell ?? RailCell(id: id)
        cell.configure(node)
        return cell
    }
}

/// One row: name on the left, line count right-aligned in tabular figures.
/// No file-type icons — the name and its place in the tree carry the meaning.
final class RailCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    /// Shown instead of the count while this file has an Edit with Claude session.
    private let sessionMark = NSImageView()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        wantsLayer = false
        label.translatesAutoresizingMaskIntoConstraints = false
        count.translatesAutoresizingMaskIntoConstraints = false
        count.alignment = .right
        count.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        addSubview(label)
        addSubview(count)
        sessionMark.translatesAutoresizingMaskIntoConstraints = false
        sessionMark.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Editing with Claude")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                .applying(.init(paletteColors: [SessionBanner.changedYellow])))
        sessionMark.isHidden = true
        addSubview(sessionMark)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            sessionMark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sessionMark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let liveMark = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Editing with Claude")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            .applying(.init(paletteColors: [SessionBanner.changedYellow])))
    private static let reviewMark = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude finished editing")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            .applying(.init(paletteColors: [.secondaryLabelColor])))

    func configure(_ node: Workspace.Node) {
        label.stringValue = node.name
        switch node.kind {
        case .section:
            label.attributedStringValue = NSAttributedString(string: node.name, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.7,
            ])
        case .project:
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
        case .package:
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.textColor = .labelColor
        case .folder:
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.textColor = .secondaryLabelColor
        case .file:
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.textColor = .labelColor
        case .action:
            label.font = .systemFont(ofSize: 12.5, weight: .regular)
            label.textColor = .tertiaryLabelColor
        }
        // The trailing figure returns, but only with a meaning. A bare line
        // count read as an unexplained number; "+7" beside a file the agent
        // rewrote while you were in the terminal explains itself.
        if let d = node.delta {
            count.stringValue = SeenStore.format(d)
            count.textColor = .secondaryLabelColor       // 100%, not 55%
            count.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        } else {
            count.stringValue = ""
            count.textColor = .tertiaryLabelColor
            count.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        // A file Claude is editing right now, or has finished editing and is
        // waiting for review, findable from anywhere in the tree.
        let session = node.kind == .file ? node.url.flatMap {
            SessionRegistry.shared.session(for: $0.path, providerID: Providers.current.id)
        } : nil
        sessionMark.isHidden = session == nil
        if let session {
            count.stringValue = ""
            sessionMark.image = session.isLive ? Self.liveMark : Self.reviewMark
            sessionMark.setAccessibilityLabel(session.isLive ? "Editing with Claude" : "Claude finished editing")
        }
    }
}
