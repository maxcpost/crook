import AppKit

// Test hook: exercise the "never run Claude Code" machine, which is the
// first thing a new user sees and is otherwise unreachable because
// NSHomeDirectory ignores $HOME.
if let h = ProcessInfo.processInfo.environment["CROOK_HOME"] { Paths.homeOverride = h }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
_ = NSDocumentController.shared
app.run()
