import Foundation
import WebKit

/// Serves the bundled editor over a custom scheme.
///
/// file:// is a trap: it breaks CORS for module loading, and — more importantly —
/// loadHTMLString leaves no URL for reload() to act on, which is the real cause
/// of the widely reported blank-web-view-after-crash. Loading over a custom
/// scheme makes webViewWebContentProcessDidTerminate recoverable (S04 §4).
final class CrookSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "crook"
    private let root: URL

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        var name = url.path
        if name.isEmpty || name == "/" { name = "/editor.html" }
        let file = root.appendingPathComponent(String(name.dropFirst()))

        guard let data = try? Data(contentsOf: file) else {
            NSLog("Crook: SCHEME MISS \(file.path)")
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        NSLog("Crook: SCHEME served \(name) (\(data.count) bytes)")
        let mime: String
        switch file.pathExtension {
        case "html": mime = "text/html"
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        default: mime = "application/octet-stream"
        }
        let resp = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
