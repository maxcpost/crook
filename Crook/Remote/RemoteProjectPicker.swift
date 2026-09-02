import AppKit

/// Choosing projects on another machine.
///
/// NSOpenPanel cannot browse a disk it has no mount for, and building a remote
/// file browser to solve that would be answering the wrong question. Claude Code
/// already keeps a directory per project it has worked in, so the agent hands
/// back that list and you tick what you want. It is less work to use than a
/// browser would have been, and it only ever offers real projects.
///
/// Nothing is added unchosen, which is the same rule the local side follows.
final class RemoteProjectPicker: NSViewController {

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var candidates: [URL] = []
    private var picked = Set<Int>()

    var onPick: (([URL]) -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))

        let title = NSTextField(labelWithString: "Add Projects from \(Providers.current.displayName)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let sub = NSTextField(wrappingLabelWithString:
            "Projects Claude Code has worked in on that machine. Nothing is added unless you choose it.")
        sub.font = .systemFont(ofSize: 11.5)
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 420

        candidates = Workspace.shared.suggestions()

        let col = NSTableColumn(identifier: .init("p"))
        col.width = 400
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .inset
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        empty.stringValue = "No projects found on that machine yet. Claude Code creates one the "
            + "first time it works in a directory."
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        empty.preferredMaxLayoutWidth = 380
        empty.isHidden = !candidates.isEmpty
        scroll.isHidden = candidates.isEmpty

        let add = NSButton(title: "Add", target: self, action: #selector(add))
        add.bezelStyle = .rounded
        add.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), cancel, add])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, sub, scroll, empty, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: sub)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func cancel() { presentingViewController?.dismiss(self) }

    @objc private func add() {
        let chosen = table.selectedRowIndexes.map { candidates[$0] }
        presentingViewController?.dismiss(self)
        guard !chosen.isEmpty else { return }
        onPick?(chosen)
    }
}

extension RemoteProjectPicker: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = candidates[row]
        let cell = NSTableCellView()
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 12.5)
        // The parent directory, dimmed. Project names repeat across a machine
        // and the leaf alone is often ambiguous.
        let parent = NSTextField(labelWithString: url.deletingLastPathComponent().path
            .replacingOccurrences(of: Providers.current.homePath, with: "~"))
        parent.font = .systemFont(ofSize: 11)
        parent.textColor = .tertiaryLabelColor
        parent.lineBreakMode = .byTruncatingHead

        let row = NSStackView(views: [name, parent])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
