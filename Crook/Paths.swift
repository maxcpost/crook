import Foundation

/// Where Crook looks for things.
///
/// NSHomeDirectory() reads the passwd entry, not the HOME environment
/// variable, so redirecting HOME does not simulate a different machine. This
/// indirection exists so the empty-machine case — a user who has never run
/// Claude Code — can actually be exercised, because it is the first thing
/// every new user sees and it is otherwise untestable.
enum Paths {
    /// Overridable for tests only. Never set in normal operation.
    static var homeOverride: String?

    static var home: String { homeOverride ?? NSHomeDirectory() }
    static var claude: String { home + "/.claude" }
    static var claudeURL: URL { URL(fileURLWithPath: claude) }

    /// Crook's own container. Never inside the user's tree — Crook does not
    /// write to the corpus it is watching.
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crook", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
