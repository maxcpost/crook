import AppKit

/// What Crook shows before there is a file.
///
/// This is the first thing every new user sees, and until now it did not
/// exist: with no document, the app launched with zero windows. A person who
/// downloads Crook has no Claude Code files open, may have none in a place
/// Crook knows about, and needs to be told what this is and what to do next —
/// in one screen, without a tour.
///
/// No illustration, no onboarding flow, no dismissible tips. One sentence and
/// one button.
final class EmptyStateView: NSView {

    private let title = NSTextField(labelWithString: "Crook")
    private let blurb = NSTextField(wrappingLabelWithString: "")
    private let action = NSButton()
    private let hint = NSTextField(wrappingLabelWithString: "")

    var onAddProject: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        blurb.stringValue = "An editor for the files that instruct Claude Code — "
            + "skills, CLAUDE.md, slash commands and memory notes."
        blurb.font = .systemFont(ofSize: 13.5)
        blurb.textColor = .secondaryLabelColor
        blurb.alignment = .center
        blurb.preferredMaxLayoutWidth = 380

        action.title = "Add a Project…"
        action.bezelStyle = .rounded
        action.controlSize = .large
        action.target = self
        action.action = #selector(add)

        hint.stringValue = "Your personal files in ~/.claude appear automatically."
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        // A single-line label clipped the longest hint at "get st".
        hint.preferredMaxLayoutWidth = 380

        let stack = NSStackView(views: [title, blurb, action, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(24, after: blurb)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    /// Adapts to what the machine actually has. Someone with Claude Code
    /// installed and someone who has never run it need different sentences.
    func refresh(hasSystemFiles: Bool, hasProjects: Bool) {
        if !hasSystemFiles && !hasProjects {
            blurb.stringValue = "An editor for the files that instruct Claude Code — "
                + "skills, CLAUDE.md, slash commands and memory notes."
            hint.stringValue = "No Claude Code files found in ~/.claude yet. "
                + "Add a project folder to get started."
        } else if !hasProjects {
            blurb.stringValue = "Your personal Claude Code files are in the sidebar. "
                + "Add a project to see the files steering Claude there."
            hint.stringValue = "Pick any folder that contains a .claude directory or a CLAUDE.md."
        } else {
            blurb.stringValue = "Choose a file in the sidebar to open it."
            hint.stringValue = "Files Claude Code rewrites while you are away are marked in the sidebar."
        }
    }

    @objc private func add() { onAddProject?() }
}
