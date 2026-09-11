import AppKit

/// What changed since you last opened this file.
///
/// A viewer, not a merge tool. There are no hunk checkboxes, no accept, no
/// reject, no staging. Claude Code wrote the file and the file is the file;
/// this exists so the reader can see what moved before carrying on. If they
/// want the old text back, they select it here and paste it into the document.
///
/// AppKit, overlaid on the editor pane — the web view stays at zero controls.
final class DiffOverlay: NSView {

    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let header = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .labelColor
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.stringValue = "esc to dismiss · the file on disk is unchanged by this view"

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 14)
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)

        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        for v in [header, hint, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            hint.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }

    /// `since` finishes the header's sentence. nil when the title already
    /// says what the diff is measured from.
    func present(old: String, new: String, title: String, since: String? = "since you last opened it",
                 onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        let (lines, summary) = UnifiedDiff.between(old, new)

        let counts = "\(summary.added) added, \(summary.removed) removed"
        let body = summary.isEmpty ? "no textual change" : (since.map { "\(counts) \($0)" } ?? counts)
        // A file outside the workspace tree has no breadcrumb; do not lead with
        // a dangling dash.
        header.stringValue = title.isEmpty ? body : "\(title) — \(body)"

        let out = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let gutter = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

        for l in lines {
            if case .gap = l.kind {
                out.append(NSAttributedString(string: "    ⋯\n", attributes: [
                    .font: gutter, .foregroundColor: NSColor.quaternaryLabelColor,
                ]))
                continue
            }
            let no = l.newNo ?? l.oldNo
            let num = (no.map { String(format: "%5d ", $0) } ?? "      ")
            out.append(NSAttributedString(string: num, attributes: [
                .font: gutter, .foregroundColor: NSColor.quaternaryLabelColor,
            ]))

            let mark: String
            var fg = NSColor.secondaryLabelColor
            var bg = NSColor.clear
            switch l.kind {
            case .added:
                mark = "+ "; fg = .labelColor
                bg = NSColor.systemGreen.withAlphaComponent(0.14)
            case .removed:
                mark = "− "; fg = .tertiaryLabelColor
                bg = NSColor.systemRed.withAlphaComponent(0.12)
            default:
                mark = "  "
            }
            out.append(NSAttributedString(string: mark + l.text + "\n", attributes: [
                .font: mono, .foregroundColor: fg, .backgroundColor: bg,
            ]))
        }

        text.textStorage?.setAttributedString(out)
        text.scrollToBeginningOfDocument(nil)
        window?.makeFirstResponder(self)
    }
}
