import AppKit

/// Edit with Claude, at the trailing end of the title bar.
///
/// A title bar accessory rather than a toolbar item. Crook has no toolbar on
/// purpose — an empty one reserves a band of chrome — and an accessory sits in
/// the title row without bringing that band back.
final class ClaudeButton: NSTitlebarAccessoryViewController {

    enum Mode: Equatable { case hidden, idle, disabled, opening, running }

    /// True when ⌥ was held: skip the popover.
    var onClick: ((_ optionHeld: Bool) -> Void)?
    private(set) var mode: Mode = .hidden
    private var compact = false

    private let button = NSButton()
    private let spinner = NSProgressIndicator()
    private let stack = NSStackView()

    /// What the popover hangs from.
    var anchor: NSView { button }

    override func loadView() {
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        button.target = self
        button.action = #selector(clicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(button)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 4),
        ])
        view = container
        apply()
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        apply()
    }

    /// Below a narrow window width the label gives way to the symbol, and
    /// moves into the tooltip.
    func setCompact(_ c: Bool) {
        guard c != compact else { return }
        compact = c
        apply()
    }

    @objc private func clicked() {
        onClick?(NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    private func apply() {
        guard isViewLoaded else { return }
        isHidden = mode == .hidden

        let title: String
        let image: NSImage?
        let help: String
        switch mode {
        case .hidden, .idle, .disabled:
            title = SessionCopy.button
            image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            help = mode == .disabled ? SessionCopy.vanishedHelp : SessionCopy.buttonHelp
        case .opening:
            title = SessionCopy.buttonOpening
            image = nil
            help = SessionCopy.buttonOpening
        case .running:
            title = SessionCopy.buttonRunning
            // Yellow means Claude: the same colour as a changed line.
            image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
                    .applying(.init(paletteColors: [SessionBanner.changedYellow])))
            help = SessionCopy.buttonRunningHelp
        }

        let showTitle = !compact || mode == .opening
        button.title = showTitle ? title : ""
        button.image = image
        button.imagePosition = showTitle ? (image == nil ? .noImage : .imageLeading) : .imageOnly
        button.toolTip = showTitle ? help : "\(title) — \(help)"
        button.setAccessibilityLabel(title)
        button.isEnabled = mode == .idle || mode == .running
        spinner.isHidden = mode != .opening
        if mode == .opening { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        // As wide as what it says, so a narrow window's title keeps the room
        // a fixed width would have taken.
        stack.layoutSubtreeIfNeeded()
        let width = ceil(stack.fittingSize.width) + 14
        if abs(view.frame.width - width) > 0.5 { view.setFrameSize(NSSize(width: width, height: 28)) }
    }
}
