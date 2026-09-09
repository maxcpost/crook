import AppKit

/// One field, because one field is all it needs.
///
/// Everything about how to reach a machine — user, port, key, jump host — is
/// already in the user's ssh config, and Crook runs the system ssh, so asking
/// again would only invite an answer that disagrees with the one that works in
/// a terminal.
///
/// The field is a combo box rather than a plain one so the answer can be
/// picked instead of remembered: it is filled with the machines Crook has
/// connected to before, then every Host alias in ~/.ssh/config. Someone who
/// has an alias that works in a terminal never has to recall how they spelled
/// it, and someone who does not can still type a hostname.
final class ConnectSheet: NSViewController {

    private let field = NSComboBox()
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton()
    private let cancelButton = NSButton()

    /// Shown only when ssh says the key is locked. Asking up front would train
    /// people to type a passphrase Crook usually does not need.
    private let passField = NSSecureTextField()
    private let passLabel = NSTextField(labelWithString: "Passphrase for the key")
    private var needsPassphrase = false

    var onConnected: ((RemoteProvider) -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 250))

        let title = NSTextField(labelWithString: "Connect to a Machine")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        subtitle.stringValue = "The name you would use with ssh. Crook uses your existing "
            + "SSH configuration, so an alias from ~/.ssh/config works here."
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 380

        field.placeholderString = "mac-mini"
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(connect)
        field.completes = true
        field.numberOfVisibleItems = 8

        // Machines already used come first — the answer is usually the last
        // answer — then the ssh config, deduped against them.
        var offered = Machines.shared.known
        for h in Machines.shared.sshConfigHosts() where !offered.contains(h) {
            offered.append(h)
        }
        field.addItems(withObjectValues: offered)
        // A combo box with nothing in it should not show a menu button that
        // opens onto an empty list.
        field.isButtonBordered = !offered.isEmpty

        if let first = Machines.shared.last ?? offered.first {
            field.stringValue = first
        }

        passLabel.font = .systemFont(ofSize: 11.5)
        passLabel.textColor = .secondaryLabelColor
        passField.font = .systemFont(ofSize: 13)
        passField.target = self
        passField.action = #selector(connect)
        passLabel.isHidden = true
        passField.isHidden = true

        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 380

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        connectButton.title = "Connect"
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        let buttons = NSStackView(views: [spinner, NSView(), cancelButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, subtitle, field, passLabel, passField, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(14, after: subtitle)
        stack.setCustomSpacing(16, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            passField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    @objc private func cancel() {
        presentingViewController?.dismiss(self)
    }

    @objc private func connect() {
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        setBusy(true, "Connecting to \(host)…")

        let pass = needsPassphrase && !passField.stringValue.isEmpty ? passField.stringValue : nil
        Machines.shared.connect(host: host, passphrase: pass) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let provider):
                self.setBusy(false, "")
                self.presentingViewController?.dismiss(self)
                self.onConnected?(provider)

            case .failure(let error):
                if case SSHTransport.Failure.authRequired = error {
                    // Only now, and only because ssh said so.
                    self.needsPassphrase = true
                    self.passLabel.isHidden = false
                    self.passField.isHidden = false
                    self.setBusy(false, "That key is protected. Enter its passphrase to continue.")
                    self.view.window?.makeFirstResponder(self.passField)
                    return
                }
                self.setBusy(false, error.localizedDescription)
            }
        }
    }

    private func setBusy(_ busy: Bool, _ message: String) {
        connectButton.isEnabled = !busy
        field.isEnabled = !busy
        passField.isEnabled = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        status.stringValue = message
        status.textColor = busy ? .secondaryLabelColor : (message.isEmpty ? .secondaryLabelColor : .systemRed)
        if busy { status.textColor = .secondaryLabelColor }
    }
}
