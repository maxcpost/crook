import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        // Retire state for files that are gone. Never ran before, so both the
        // entry map and the snapshot directory grew without bound.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            SeenStore.shared.prune()
        }

        // Cold start (01-design §4): open the file we were handed, else an
        // untitled document. Never a blank window, never an illustration.
        let dc = NSDocumentController.shared
        // Drop flags AND their values. "-NSDocumentRevisionsDebugMode YES"
        // otherwise leaves "YES" looking like a path to open.
        var args: [String] = []
        var skipNext = false
        for a in CommandLine.arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if a.hasPrefix("-") { skipNext = true; continue }
            args.append(a)
        }

        // Always put a window on screen. Relying on
        // openUntitledDocumentAndDisplay was the bug: the markdown type is
        // declared with role Viewer (so Crook does not hijack .md files), and
        // AppKit will not create an untitled document for a Viewer-role type.
        // On a machine with no Claude Code files the app launched with ZERO
        // windows — the first thing a new user would have seen.
        func showWorkspace() {
            let wc = WorkspaceWindowController.shared
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
        }

        if let path = args.first {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            dc.openDocument(withContentsOf: url, display: true) { doc, _, err in
                if err != nil || doc == nil {
                    NSLog("Crook: could not open \(url.path)")
                    showWorkspace()
                }
            }
        } else {
            showWorkspace()
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        return true
    }

    /// D-19 refuses a command palette on the promise that the menu bar carries
    /// the verbs. This is the minimum for step 1; S08 specifies the full set.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Crook", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Crook", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Crook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let reload = NSMenuItem(title: "Reload from Disk",
                                action: #selector(CrookDocument.reloadFromDiskDiscardingEdits(_:)),
                                keyEquivalent: "r")
        reload.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(reload)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // View — the zoom trio. Responder-chain targeted, so it reaches
        // whichever EditorViewController is in the key window.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let zin = NSMenuItem(title: "Bigger Text", action: Selector(("zoomIn:")), keyEquivalent: "+")
        zin.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zin)
        // "+" is Shift+= on a US layout, so bind "=" as the unshifted twin the
        // way every Mac app does; otherwise Cmd-+ only fires with Shift held.
        let zinAlt = NSMenuItem(title: "Bigger Text", action: Selector(("zoomIn:")), keyEquivalent: "=")
        zinAlt.keyEquivalentModifierMask = [.command]
        zinAlt.isAlternate = false
        zinAlt.isHidden = true
        viewMenu.addItem(zinAlt)
        let zout = NSMenuItem(title: "Smaller Text", action: Selector(("zoomOut:")), keyEquivalent: "-")
        zout.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zout)
        let zreset = NSMenuItem(title: "Actual Size", action: Selector(("zoomReset:")), keyEquivalent: "0")
        zreset.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zreset)
        viewMenu.addItem(.separator())
        let changes = NSMenuItem(title: "Show Changes",
                                 action: Selector(("showChanges:")), keyEquivalent: "d")
        changes.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(changes)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
