import AppKit

/// The strip across the top of the editor while a file is in an Edit with
/// Claude session, and after one ends.
///
/// AppKit, like every control in Crook; the web view stays at zero controls.
/// Its colours are Crook's own paper with a trace of highlighter, and its dot is
/// the yellow the editor marks changed lines with — yellow means Claude.
final class SessionBanner: NSView {

    var onAction: ((BannerContent.Action) -> Void)?
    var onOpenFile: ((String) -> Void)?
    private(set) var content: BannerContent?

    private let dot = BannerDot()
    private let titleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private let alsoRow = NSStackView()
    private let separator = NSBox()

    private static let actions: [BannerContent.Action] = [.showTerminal, .endSession, .review, .undo, .redo, .done]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 10, for: .horizontal)
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        alsoRow.orientation = .horizontal
        alsoRow.spacing = 3
        separator.boxType = .separator

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [dot, titleLabel, noteLabel, spacer, buttonRow])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8

        let rows = NSStackView(views: [top, alsoRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 3
        rows.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)

        for v in [rows, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: separator.topAnchor),
            top.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ c: BannerContent) {
        guard c != content else { return }
        content = c
        titleLabel.stringValue = c.title
        noteLabel.stringValue = c.note ?? ""
        noteLabel.isHidden = c.note == nil
        dot.color = Self.dotColor(c.tone)
        setAccessibilityLabel([c.title, c.note].compactMap { $0 }.joined(separator: ". "))

        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for b in c.buttons {
            let button = NSButton(title: b.title, target: self, action: #selector(tapped(_:)))
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.isEnabled = b.enabled
            button.toolTip = b.help
            button.tag = Self.actions.firstIndex(of: b.action) ?? 0
            buttonRow.addArrangedSubview(button)
        }

        alsoRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        alsoRow.isHidden = c.alsoChanged.isEmpty
        if !c.alsoChanged.isEmpty {
            alsoRow.addArrangedSubview(Self.small("Also changed during the session:"))
            let shown = Array(c.alsoChanged.prefix(3))
            for (i, path) in shown.enumerated() {
                let link = NSButton(title: path, target: self, action: #selector(openFile(_:)))
                link.isBordered = false
                link.font = .systemFont(ofSize: 11.5)
                link.contentTintColor = .labelColor
                link.setAccessibilityLabel("Open \(path)")
                alsoRow.addArrangedSubview(link)
                if i < shown.count - 1 { alsoRow.addArrangedSubview(Self.small(",")) }
            }
            if c.alsoChanged.count > 3 { alsoRow.addArrangedSubview(Self.small("and \(c.alsoChanged.count - 3) more")) }
        }
        needsDisplay = true
    }

    /// Someone tried to type: draw the eye here, once, unless motion is reduced.
    func pulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Self.changedYellow.cgColor
        }
        layer.borderWidth = 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.layer?.borderWidth = 0 }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let tone = content?.tone ?? .live
        layer?.backgroundColor = (tone == .live || tone == .attention ? Self.liveTint : Self.endedTint).cgColor
    }

    @objc private func tapped(_ sender: NSButton) {
        guard Self.actions.indices.contains(sender.tag) else { return }
        onAction?(Self.actions[sender.tag])
    }

    @objc private func openFile(_ sender: NSButton) { onOpenFile?(sender.title) }

    private static func small(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = .secondaryLabelColor
        return l
    }

    // MARK: - colour

    private static func color(light: UInt32, dark: UInt32) -> NSColor {
        func make(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? make(dark) : make(light)
        }
    }

    /// Paper with a trace of highlighter, while Claude has the file.
    static let liveTint = color(light: 0xFAF3DA, dark: 0x2A2619)
    /// Plain warm paper once it's over.
    static let endedTint = color(light: 0xF4F1E9, dark: 0x24221E)
    /// theme.css --c-changed: the colour of a line Claude changed.
    static let changedYellow = color(light: 0xC79A2E, dark: 0xD8B25C)

    private static func dotColor(_ tone: BannerContent.Tone) -> NSColor {
        switch tone {
        case .live, .attention: return changedYellow
        case .warning: return .systemRed
        case .ended: return .tertiaryLabelColor
        }
    }
}

/// A small round mark in a colour that follows the appearance.
private final class BannerDot: NSView {
    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = bounds.height / 2
    }
}
