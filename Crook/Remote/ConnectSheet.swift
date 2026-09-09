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

    /// Shown only when ssh says a secret is needed, and labelled with the one
    /// it actually asked for — a key passphrase and an account password are
    /// different things to go and find. Asking up front would train people to
    /// type something Crook usually does not need at all.
    private let passField = NSSecureTextField()
    private let passLabel = NSTextField(labelWithString: "")
    private var wanted: SSHTransport.Secret?
    private var busy = false
    /// Set by Cancel. A connection already in flight cannot be recalled, but
    /// its result can be thrown away rather than adopted behind a closed sheet.
    private var cancelled = false

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
        // No action on the field. NSComboBox sends its action when an item is
        // PICKED from the list, so wiring it to connect() meant choosing a
        // machine started the connection before the pick could be corrected
        // or a password typed. Return still connects: the Connect button is
        // the window's default and takes the key from the field editor.
        field.delegate = self
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
        cancelled = true
        presentingViewController?.dismiss(self)
    }

    /// The host changed under a secret typed for a different one.
    ///
    /// Without this, host A's password was carried into the FIRST attempt at
    /// host B: sent to B's sshd, and B's own "I need a password" turned into a
    /// hard failure because an attempt made WITH a secret is never asked
    /// again. A secret belongs to the machine it was typed for.
    private func hostChanged() {
        guard wanted != nil || !status.stringValue.isEmpty else { return }
        wanted = nil
        passField.stringValue = ""
        passLabel.isHidden = true
        passField.isHidden = true
        status.stringValue = ""
    }

    @objc private func connect() {
        guard !busy else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        cancelled = false
        setBusy(true, "Connecting to \(host)…")

        let pass = wanted != nil && !passField.stringValue.isEmpty ? passField.stringValue : nil
        Machines.shared.connect(host: host, secret: pass) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let provider):
                self.setBusy(false, "")
                if self.cancelled {
                    // The sheet is gone and nobody asked for this any more.
                    Machines.shared.disconnect()
                    return
                }
                self.presentingViewController?.dismiss(self)
                self.onConnected?(provider)

            case .failure(let error):
                if case SSHTransport.Failure.authRequired(let want) = error {
                    // Only now, and only because ssh said so.
                    self.wanted = want
                    self.passLabel.stringValue = want.prompt
                    self.passLabel.isHidden = false
                    self.passField.isHidden = false
                    self.passField.stringValue = ""
                    switch want {
                    case .keyPassphrase:
                        self.setBusy(false, "That key is locked. Enter its passphrase to continue.")
                    case .accountPassword:
                        self.setBusy(false, "\(host) wants a password. This is the login "
                            + "password for your account on that Mac.")
                    }
                    self.view.window?.makeFirstResponder(self.passField)
                    return
                }
                self.setBusy(false, error.localizedDescription)
            }
        }
    }

    private func setBusy(_ busy: Bool, _ message: String) {
        self.busy = busy
        connectButton.isEnabled = !busy
        field.isEnabled = !busy
        passField.isEnabled = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        status.stringValue = message
        status.textColor = busy ? .secondaryLabelColor : (message.isEmpty ? .secondaryLabelColor : .systemRed)
        if busy { status.textColor = .secondaryLabelColor }
    }
}

extension ConnectSheet: NSComboBoxDelegate {
    func controlTextDidChange(_ obj: Notification) { hostChanged() }
    func comboBoxSelectionDidChange(_ notification: Notification) { hostChanged() }
}
