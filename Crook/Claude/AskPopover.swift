import AppKit

/// The question Edit with Claude asks before Terminal opens.
///
/// Typing is optional; Return always opens the session. It exists because the
/// first instruction is usually the only one, and it is better given here — in
/// the app the person is already looking at, beside the selection it applies
/// to — than typed into Terminal after waiting for a greeting.
final class AskPopover: NSViewController, NSTextViewDelegate {

    struct Context {
        var breadcrumb: String
        var selectedLines: ClosedRange<Int>?
        var machineName: String?
        var showTip: Bool
        var showFirstTime: Bool
        var draft: String
        /// Inside a .claude folder, where Claude Code asks before each change.
        var asksBeforeEditing = false
    }

    var onOpen: ((String) -> Void)?
    var onDraftChange: ((String) -> Void)?

    private let context: Context
    private let textView = NSTextView()
    private let placeholder = NSTextField(wrappingLabelWithString: SessionCopy.placeholder)
    private var fieldHeight: NSLayoutConstraint!

    private static let width: CGFloat = 340
    private static let lineHeight: CGFloat = 17

    init(context: Context) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let inner = Self.width - 28

        let crumb = NSTextField(labelWithString: context.breadcrumb)
        crumb.font = .systemFont(ofSize: 12, weight: .semibold)
        crumb.lineBreakMode = .byTruncatingMiddle
        crumb.widthAnchor.constraint(lessThanOrEqualToConstant: inner).isActive = true
        var rows: [NSView] = [crumb]

        if let lines = context.selectedLines {
            rows.append(Self.label(SessionCopy.selectionNote(lines), size: 11.5, color: .secondaryLabelColor, width: inner))
        } else if context.showTip {
            rows.append(Self.label(SessionCopy.tip, size: 11.5, color: .tertiaryLabelColor, width: inner))
        }

        rows.append(makeField(width: inner))
        rows.append(Self.label(SessionCopy.footer(machine: context.machineName), size: 11,
                               color: .secondaryLabelColor, width: inner))
        if context.asksBeforeEditing {
            rows.append(Self.label(SessionCopy.asksFirst, size: 11, color: .secondaryLabelColor, width: inner))
        }
        if context.showFirstTime {
            // The one line that heads off a declined trust question: readable,
            // not faint.
            rows.append(Self.label(SessionCopy.firstTime, size: 11, color: .secondaryLabelColor, width: inner))
        }

        let open = NSButton(title: SessionCopy.openButton, target: self, action: #selector(openTapped))
        open.bezelStyle = .push
        open.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [NSView(), open])
        buttonRow.orientation = .horizontal
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        rows.append(buttonRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
            buttonRow.widthAnchor.constraint(equalToConstant: inner),
        ])
        view = root
        updateHeight()
    }

    private func makeField(width: CGFloat) -> NSView {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 3, height: 5)
        // What the person types reaches Claude verbatim; curly quotes and
        // dashes it did not type would reach it too.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.frame = NSRect(x: 0, y: 0, width: width - 2, height: 60)
        textView.string = context.draft
        textView.delegate = self
        textView.setAccessibilityLabel(SessionCopy.requestLabel)
        textView.setAccessibilityPlaceholderValue(SessionCopy.placeholder)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        placeholder.preferredMaxLayoutWidth = width - 20
        placeholder.isHidden = !context.draft.isEmpty
        // The field already says this to VoiceOver.
        placeholder.setAccessibilityElement(false)

        let box = FieldBox()
        for v in [box, scroll, placeholder] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        box.addSubview(scroll)
        box.addSubview(placeholder)
        fieldHeight = box.heightAnchor.constraint(equalToConstant: Self.lineHeight * 3 + 12)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            fieldHeight,
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            placeholder.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            placeholder.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -9),
        ])
        return box
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Return opens the session; Shift-Return starts a new line.
    func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            tv.insertNewlineIgnoringFieldEditor(nil)
        } else {
            openTapped()
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        onDraftChange?(textView.string)
        updateHeight()
    }

    @objc private func openTapped() { onOpen?(textView.string) }

    /// Three lines tall, growing with the request to eight, then scrolling.
    private func updateHeight() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let lineHeight = lm.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
        let used = lm.usedRect(for: tc).height
        let lines = max(3, min(8, Int((used / lineHeight - 0.01).rounded(.up))))
        fieldHeight.constant = CGFloat(lines) * lineHeight + textView.textContainerInset.height * 2 + 2
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private static func label(_ s: String, size: CGFloat, color: NSColor, width: CGFloat) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.preferredMaxLayoutWidth = width
        return l
    }
}

/// The request field's frame: a hairline and the text background, like any
/// other text field.
private final class FieldBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
