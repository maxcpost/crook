import Foundation
import AppKit

/// Every case here was a real defect found in review. They are the tests that
/// should have existed before the code shipped.
enum RegressionTests {
    static func run() {
        T.suite("regressions — data loss found in review")

        // A detached document must never serialise the shared editor's buffer.
        // It used to, so editing A and then opening B made A's next autosave
        // write B's bytes over A.md.
        let a = CrookDocument(), b = CrookDocument()
        try! a.read(from: Data("AAA original\n".utf8), ofType: "net.daringfireball.markdown")
        try! b.read(from: Data("BBB different\n".utf8), ofType: "net.daringfireball.markdown")
        let vc = EditorViewController()
        _ = vc.view
        let lf = ByteProfile(lineEnding: .lf, hasFinalNewline: true, bom: nil,
                             encoding: .utf8, mixedLineEndings: false)
        a.attach(to: vc)
        vc.bridge.load(text: NSMutableString(string: "AAA original\n"), profile: lf)
        b.attach(to: vc)
        vc.bridge.load(text: NSMutableString(string: "BBB different\n"), profile: lf)
        let aBytes = String(decoding: (try! a.data(ofType: "net.daringfireball.markdown")), as: UTF8.self)
        T.ok("R-01  a detached document keeps its OWN text",
             aBytes.hasPrefix("AAA"), "got \(aBytes.debugDescription)")
        let bBytes = String(decoding: (try! b.data(ofType: "net.daringfireball.markdown")), as: UTF8.self)
        T.ok("R-02  the attached document still reads the live buffer", bBytes.hasPrefix("BBB"))

        // Encoding must refuse rather than truncate. A latin1 file that gains a
        // character above U+00FF used to save as ZERO BYTES.
        let latin = Data([0x41, 0x42, 0xE9, 0x0A])
        let (t, prof) = try! ByteCodec.decode(latin)
        T.eq("R-03  an invalid-UTF-8 file falls back to latin1", prof.encoding, .isoLatin1)
        t.append("\u{1F600}")
        var threw = false
        do { _ = try ByteCodec.encode(t, profile: prof) } catch { threw = true }
        T.ok("R-04  an unencodable edit throws instead of writing 0 bytes", threw)

        // A named subagent must be named. Every valid agent file used to claim
        // "no name: field, so Claude Code skips it".
        let agent = URL(fileURLWithPath: "/tmp/proj/.claude/agents/reviewer.md")
        let named = "---\nname: reviewer\ndescription: reviews things\n---\n\nbody\n"
        T.eq("R-05  a subagent with a name says so",
             ReachClassifier.subtitle(for: agent, text: named),
             "Subagent · Claude delegates to reviewer")
        T.eq("R-06  and one without still warns",
             ReachClassifier.subtitle(for: agent, text: "---\ndescription: x\n---\n"),
             "Subagent · no name: field, so Claude Code skips it")

        // A project whose directory name contains a hyphen must decode. Claude
        // Code slugs a path by replacing "/" with "-", which is lossy, so the
        // decoder has to re-join components greedily against the filesystem; it
        // used to swap every "-" for a "/" and dropped every hyphenated project.
        //
        // Built in a temp directory rather than derived from the checkout. Where
        // the repository lives is not this test's subject, and a checkout path
        // with a component of its own that begins with "-" is not representable
        // as a slug at all — the old form asserted against ~/Desktop/Crook and
        // so tested the author's filesystem layout as much as the decoder.
        let fmgr = FileManager.default
        let slugBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("crook-slug-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        let real = slugBase.appendingPathComponent("atlas-relay/packages/web-ui", isDirectory: true)
            .standardizedFileURL
        try? fmgr.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fmgr.removeItem(at: slugBase) }
        let slug = "-" + real.path.dropFirst().replacingOccurrences(of: "/", with: "-")
        T.eq("R-07  a slug round-trips through a real path with three hyphens in it",
             Workspace.decodeSlug(slug) ?? "nil", real.path)
        T.ok("R-07b and the hyphens were the hard part",
             real.path.contains("atlas-relay") && real.path.contains("web-ui"))

        // R-07c: the decoy. A directory whose name is a PREFIX of the one we
        // want, in the same parent, derails a greedy decoder: it takes the
        // short match, cannot resolve the rest, and gives up — and the real
        // project silently never appears in the picker. Not exotic at all;
        // it is `web` beside `web-ui`, or `atlas` beside `atlas-relay`.
        //
        // R-07 hit this only by accident. WebKit creates a directory called
        // "crook" in TMPDIR while the suite runs, and the fixture above is
        // "crook-slug-<pid>", so R-07 passed or failed on whether WebKit had
        // started yet. This builds the decoy on purpose instead.
        let decoyBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("crook-decoy-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        let wanted = decoyBase.appendingPathComponent("atlas-relay/web-ui", isDirectory: true)
            .standardizedFileURL
        try? fmgr.createDirectory(at: wanted, withIntermediateDirectories: true)
        for trap in ["atlas", "atlas-relay/web"] {
            try? fmgr.createDirectory(at: decoyBase.appendingPathComponent(trap, isDirectory: true),
                                      withIntermediateDirectories: true)
        }
        defer { try? fmgr.removeItem(at: decoyBase) }

        func slugFor(_ path: String) -> String {
            "-" + path.dropFirst().replacingOccurrences(of: "/", with: "-")
        }
        T.eq("R-07c a shorter sibling does not swallow the path it prefixes",
             Workspace.decodeSlug(slugFor(wanted.path)) ?? "nil", wanted.path)

        let decoy = decoyBase.appendingPathComponent("atlas", isDirectory: true).standardizedFileURL
        T.eq("R-07d and the decoy still decodes to itself",
             Workspace.decodeSlug(slugFor(decoy.path)) ?? "nil", decoy.path)

        T.ok("R-07e a slug for a path that does not exist is still nil",
             Workspace.decodeSlug(slugFor(decoyBase.appendingPathComponent("nope-not-here").path)) == nil)
    }
}
