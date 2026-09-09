import AppKit

// Test hook: exercise the "never run Claude Code" machine, which is the
// first thing a new user sees and is otherwise unreachable because
// NSHomeDirectory ignores $HOME.
if let h = ProcessInfo.processInfo.environment["CROOK_HOME"] { Paths.homeOverride = h }

// Turn off every macOS text substitution, for this app only.
//
// These are system services that insert characters the user never typed —
// curly quotes, en and em dashes, ellipses, capitalisation, a period from a
// double space, and any registered text replacement. They arrive from the
// AppKit side, which is the one path CodeMirror's own kill-list cannot cover,
// and the golden-file round trip cannot catch them because it types an ASCII
// character and deletes it.
//
// In an app whose single non-negotiable claim is that the bytes you saved are
// the bytes on disk, a curly quote silently replacing a straight one in a file
// a parser reads is a defect, not a nicety. Registering these in Crook's own
// defaults domain disables them HERE without touching the user's system
// settings or any other app.
UserDefaults.standard.register(defaults: [
    "NSAutomaticQuoteSubstitutionEnabled": false,
    "NSAutomaticDashSubstitutionEnabled": false,
    "NSAutomaticTextReplacementEnabled": false,
    "NSAutomaticCapitalizationEnabled": false,
    "NSAutomaticPeriodSubstitutionEnabled": false,
    "NSAutomaticSpellingCorrectionEnabled": false,
    "WebAutomaticQuoteSubstitutionEnabled": false,
    "WebAutomaticDashSubstitutionEnabled": false,
    "WebAutomaticTextReplacementEnabled": false,
    "WebAutomaticSpellingCorrectionEnabled": false,
    "WebContinuousSpellCheckingEnabled": false,
])

// SIGPIPE's default disposition is to kill the process. Crook writes into pipes
// to ssh constantly, and ssh can exit at any moment — a dropped link, a wrong
// password, a machine going to sleep. The write must fail with EPIPE and be
// handled, not take the app down. Process-wide, and before anything can write.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
// The first NSDocumentController created becomes the shared one. It has to be
// ours, and it has to be before anything asks for .shared.
let documents = CrookDocumentController()
precondition(NSDocumentController.shared === documents,
             "another NSDocumentController was created before CrookDocumentController")
app.run()
