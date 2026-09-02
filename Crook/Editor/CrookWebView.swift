import AppKit
import WebKit

/// A stock WKWebView consumes every Command chord before the AppKit main menu
/// sees it — including Cmd+Return, the core gesture of the whole application.
/// Measured: viewConsumed=true with the menu action never firing.
///
/// Returning false for a reserved chord lets it fall through to the menu.
/// Plain keys never enter performKeyEquivalent at all, so typing and IME are
/// untouched (S04 §7).
final class CrookWebView: WKWebView {

    /// Derived from the menu spec. Any chord here belongs to AppKit, not the page.
    static let reserved: Set<String> = [
        "\r",           // Cmd+Return — follow reference
        "o", "p",       // opener, print
        "s", "w", "n", "t",
        "[", "]",       // back / forward
        "u",            // up to package anchor
        "e",            // package issues
        "f", "g",
        "1", "2", "3", "4", "5", "6", "0",
        "+", "=", "-",  // zoom; the web view would otherwise take them
        "d",            // show changes
        "r",            // reload from disk; WebKit would take it as page reload
        "/",            // source mode
        ",",
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if Self.reserved.contains(key) {
            return false  // fall through to NSApp.mainMenu
        }
        return super.performKeyEquivalent(with: event)
    }
}
