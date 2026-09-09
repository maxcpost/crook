import Foundation

/// What the agent is told it may serve.
///
/// The agent refuses to read a path outside the roots it was given. That is
/// deliberate — it bounds what a client-side bug can reach — but it means the
/// root set has to be the whole truth about what this machine's window is
/// showing, and it was assembled twice from two momentary lists instead.
///
/// On connect it was `~/.claude` and nothing else, so every project imported in
/// an earlier session was silently dropped: the sidebar still drew the file,
/// because `exists` falls back to a `stat` the agent does NOT gate, and then
/// clicking it did nothing at all, because `read` IS gated. A file you can see
/// and cannot open, with no error anywhere.
///
/// On add it was `~/.claude` plus the projects picked in that one sheet, so
/// adding a second project un-declared the first without touching the sidebar.
///
/// Both are the same mistake. The roots are a function of what this machine has
/// imported, which is already persisted per machine, so there is exactly one
/// correct answer and one place to compute it.
enum ProjectRootsTests {

    private static let providerID = "ssh:crook-test-machine"
    private static let key = "CrookImportedProjects::ssh:crook-test-machine"
    private static let home = "/Users/far"

    static func run() {
        T.suite("projects — what the far machine is allowed to serve")

        let defaults = UserDefaults.standard
        let saved = defaults.array(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let alpha = "/Users/far/Documents/labs/alpha"
        let beta = "/Users/far/Documents/labs/beta-two"

        // P-01: nothing imported yet — just the personal tree.
        defaults.removeObject(forKey: key)
        T.eq("P-01  with no projects, the roots are ~/.claude alone",
             Workspace.remoteRoots(home: home, providerID: providerID).joined(separator: " "),
             "/Users/far/.claude")

        // P-02/P-03: the reconnect case. A project imported in an earlier
        // session must come back, or its files are visible and unopenable.
        defaults.set([alpha], forKey: key)
        let one = Workspace.remoteRoots(home: home, providerID: providerID)
        T.ok("P-02  a project imported earlier is declared again on connect",
             one.contains(alpha), one.joined(separator: " "))
        T.ok("P-03  and ~/.claude is still there", one.contains("/Users/far/.claude"))

        // P-04: the second-add case. Adding beta must not un-declare alpha.
        defaults.set([alpha, beta], forKey: key)
        let both = Workspace.remoteRoots(home: home, providerID: providerID)
        T.ok("P-04  adding a second project keeps the first", both.contains(alpha), both.joined(separator: " "))
        T.ok("P-05  and declares the second", both.contains(beta))
        T.eq("P-06  with no duplicates and the personal tree first",
             both.joined(separator: " "),
             "/Users/far/.claude \(alpha) \(beta)")

        // P-07: a machine's projects belong to that machine. Asking for one id
        // must never hand back another's paths — that would declare roots the
        // far side has no business serving.
        let otherKey = "CrookImportedProjects::ssh:someone-else"
        defaults.set(["/Users/far/Documents/not-this-one"], forKey: otherKey)
        defer { defaults.removeObject(forKey: otherKey) }
        T.ok("P-07  another machine's imports are not declared here",
             !Workspace.remoteRoots(home: home, providerID: providerID)
                 .contains("/Users/far/Documents/not-this-one"))

        // P-08: this Mac's own projects live under the unsuffixed key and must
        // not leak into a remote machine's roots either.
        let localKey = "CrookImportedProjects"
        let localSaved = defaults.array(forKey: localKey)
        defaults.set(["/Users/here/my-local-project"], forKey: localKey)
        defer {
            if let localSaved { defaults.set(localSaved, forKey: localKey) }
            else { defaults.removeObject(forKey: localKey) }
        }
        T.ok("P-08  and neither do this Mac's",
             !Workspace.remoteRoots(home: home, providerID: providerID)
                 .contains("/Users/here/my-local-project"))
    }
}
