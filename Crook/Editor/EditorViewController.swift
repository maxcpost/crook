import AppKit
import WebKit

final class EditorViewController: NSViewController, WKUIDelegate {
    let bridge = EditorBridge()
    private var webView: CrookWebView!
    private var topConstraint: NSLayoutConstraint?
    /// The reach readout. AppKit, overlaid on the editor pane — never inside
    /// the web view, which stays at zero controls in every state.
    private var reachLabel: NSTextField!
    private var reachChip: ReachChip!
    private var diff: DiffOverlay?
    private var empty: EmptyStateView!
    /// The document currently displayed. There is ONE editor, so a document
    /// that has been detached must not read this bridge — it holds someone
    /// else's text.
    weak var owner: AnyObject?

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        let resourceRoot = Bundle.main.resourceURL!.appendingPathComponent("web")
        cfg.setURLSchemeHandler(CrookSchemeHandler(root: resourceRoot),
                                forURLScheme: CrookSchemeHandler.scheme)
        cfg.userContentController.add(bridge, name: "crook")
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        // A blocked inline <script> does not reach window.onerror, so the page
        // gets its error and console channels injected instead.
        let logger = WKUserScript(source: """
            window.onerror = function(m, s, l, c) {
              window.webkit.messageHandlers.crook.postMessage({type:'jserror', message: String(m), line: l});
            };
            console.log = function() {
              window.webkit.messageHandlers.crook.postMessage({type:'console', message: Array.from(arguments).map(String).join(' ')});
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        cfg.userContentController.addUserScript(logger)

        // A plain container. The web view is inset from the top by the window's
        // contentLayoutGuide so the titlebar and — critically — the native tab
        // bar never draw over the text. With fullSizeContentView the content
        // view fills the whole window, so without this the first heading sits
        // underneath the tabs.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))

        webView = CrookWebView(frame: container.bounds, configuration: cfg)
        webView.navigationDelegate = bridge
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Bottom-right, the way a browser parks a link preview: always there,
        // never in the way, and it explains the thing you are looking at
        // rather than the thing you clicked.
        reachLabel = NSTextField(labelWithString: "")
        reachLabel.font = .systemFont(ofSize: 11, weight: .regular)
        reachLabel.textColor = .tertiaryLabelColor
        reachLabel.lineBreakMode = .byTruncatingHead
        reachLabel.alignment = .right
        reachLabel.translatesAutoresizingMaskIntoConstraints = false

        // The label needs something behind it. It floats over the web view, and
        // scrolled anywhere but the end of a document there is body text under
        // that corner — two greys at similar weight, overlapping. It read as a
        // rendering fault rather than a readout. An opaque chip in the editor's
        // own background colour separates the two without introducing a rule or
        // a status bar, and it disappears against the page when the corner is
        // empty, which is most of the time.
        reachChip = ReachChip()
        reachChip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reachChip)
        reachChip.addSubview(reachLabel)
        NSLayoutConstraint.activate([
            reachChip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            reachChip.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            reachChip.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            reachLabel.leadingAnchor.constraint(equalTo: reachChip.leadingAnchor, constant: 8),
            reachLabel.trailingAnchor.constraint(equalTo: reachChip.trailingAnchor, constant: -8),
            reachLabel.topAnchor.constraint(equalTo: reachChip.topAnchor, constant: 4),
            reachLabel.bottomAnchor.constraint(equalTo: reachChip.bottomAnchor, constant: -4),
        ])

        // Shown whenever there is no document. Sits above the web view rather
        // than replacing it, so opening a file is an instant reveal.
        empty = EmptyStateView(frame: container.bounds)
        empty.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.topAnchor.constraint(equalTo: container.topAnchor),
            empty.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        bridge.webView = webView
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: URL(string: "crook://local/editor.html")!))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        attachToContentLayoutGuide()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The editor is where the caret lives. Without this the web view is
        // never first responder and every Edit-menu command — Select All
        // included — targets nothing.
        //
        // makeFirstResponder alone is not enough, which is the subtle half:
        // it hands AppKit keyboard focus to the WKWebView, but the page's
        // contenteditable inside it stays unfocused, so keystrokes arrive at
        // the web view and CodeMirror ignores them. Both halves are required.
        focusEditor()
        applyStoredScale()
    }

    /// contentLayoutGuide tracks the titlebar AND the tab bar, so the inset is
    /// correct whether or not tabs are showing, and updates when one opens.
    private func attachToContentLayoutGuide() {
        guard let window = view.window, topConstraint == nil else { return }
        _ = window
        guard false, let guide = view.window?.contentLayoutGuide as? NSLayoutGuide else {
            // The pane already begins below the chrome, so the web view simply
            // fills it.
            let c = webView.topAnchor.constraint(equalTo: view.topAnchor)
            c.isActive = true
            topConstraint = c
            return
        }
        let c = webView.topAnchor.constraint(equalTo: guide.topAnchor)
        c.isActive = true
        topConstraint = c
    }

    /// Text size. Persisted, because a size you have to reset every launch is
    /// worse than no control at all.
    private static let scaleKey = "CrookTextScale"

    func applyStoredScale() {
        let i = UserDefaults.standard.object(forKey: Self.scaleKey) as? Int ?? 2
        webView.evaluateJavaScript("CrookEditor.setScale(\(i));")
    }

    @objc func zoomIn(_ sender: Any?)    { zoom("zoomIn") }
    @objc func zoomOut(_ sender: Any?)   { zoom("zoomOut") }
    @objc func zoomReset(_ sender: Any?) { zoom("zoomReset") }

    private func zoom(_ fn: String) {
        webView.evaluateJavaScript("CrookEditor.\(fn)();") { v, _ in
            if let i = v as? Int { UserDefaults.standard.set(i, forKey: Self.scaleKey) }
        }
    }

    // MARK: - the change view

    /// Read-only. Nothing here writes to the document or to disk.
    func showDiff(old: String, new: String, title: String) {
        dismissDiff()
        let d = DiffOverlay(frame: view.bounds)
        d.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(d)
        NSLayoutConstraint.activate([
            d.topAnchor.constraint(equalTo: view.topAnchor),
            d.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            d.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            d.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        diff = d
        d.present(old: old, new: new, title: title) { [weak self] in self?.dismissDiff() }
    }

    @discardableResult
    func dismissDiff() -> Bool {
        guard let d = diff else { return false }
        d.removeFromSuperview()
        diff = nil
        focusEditor()
        return true
    }

    /// Show or hide the empty state. Called whenever the open document changes.
    func showEmptyState(_ show: Bool, onAddProject: (() -> Void)? = nil,
                        onConnect: (() -> Void)? = nil) {
        empty.isHidden = !show
        reachChip.isHidden = show
        if show {
            if let onAddProject { empty.onAddProject = onAddProject }
            if let onConnect { empty.onConnect = onConnect }
            empty.refresh(hasSystemFiles: !Workspace.shared.system.isEmpty,
                          hasProjects: !Workspace.shared.projects.isEmpty)
        }
    }

    func setReach(_ text: String) {
        guard reachLabel.stringValue != text else { return }
        reachLabel.stringValue = text
        // Nothing to separate when there is nothing to say.
        reachChip.isHidden = text.isEmpty
    }



    func focusEditor() {
        view.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("CrookEditor.focus();")
    }
}

/// The backing behind the reach readout.
///
/// A view rather than a colour set once, because the appearance can change
/// under it — the toggle in the corner, or the system switching at sunset —
/// and updateLayer is the only hook that fires for both.
private final class ReachChip: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}
