import Foundation

/// What makes Claude Code read this file.
///
/// This is the shared path-classification component. Reached By (F1) turns its
/// result into a sentence; Dead Path Resolution (F2) uses `role` as its gate,
/// scanning only files that have a Claude Code role at all.
///
/// THE ONE RULE: when the path is not one Crook has a sentence for, the answer
/// is nothing. Never a guess, never a hedge, never a partial. 141 of the 270
/// fixture files resolve to empty, and that is the correct majority behaviour
/// for a feature that must never be wrong.
enum ReachClassifier {

    enum Role {
        case personalSkill(command: String)
        case projectSkill(command: String)
        case unscannedSkill
        case packageSupport
        case personalCommand(name: String)
        case projectCommand(name: String)
        case personalMemory
        case projectMemory
        case localMemory
        case agentsRead
        case agentsIgnored
        case personalRule(pattern: String?)
        case projectRule(pattern: String?)
        case unreadablePathsRule
        case subagent(name: String)
        case unnamedSubagent
        case personalSettings
        case projectSettings
        case unknown
    }

    /// Does Claude Code read this file as instructions?
    ///
    /// NOT the same question as "does Crook have a sentence for it". Deriving
    /// this from `classify() != .unknown` silences the scanner on 141 of 270
    /// fixture files, 4 of which carry 6 real dead references — including
    /// project_atlas.md, which has 3. A memory node has no reach sentence
    /// because nothing about its path is worth stating, but its contents are
    /// injected into context, so a dead path inside it is exactly as broken.
    ///
    /// The rule is simply: if Crook shows the file, Claude Code reads it.
    static func readsInstructions(_ url: URL) -> Bool {
        Workspace.isClaudeFile(url)
    }

    /// Deprecated name kept for the classifier's own use.
    static func hasRole(_ url: URL) -> Bool { readsInstructions(url) }

    /// Does Claude Code PARSE this file's frontmatter as YAML?
    ///
    /// Strictly narrower than readsInstructions. A memory file is read as
    /// content top to bottom, so a `---` block at its head is text and a
    /// complaint about its YAML would be a complaint about nothing. Same for a
    /// package's supporting files — which is most of the markdown on this
    /// machine, and which is exactly where a horizontal rule under a heading
    /// lives. Only these four roles have a header that gets parsed.
    static func parsesFrontmatter(_ url: URL) -> Bool {
        switch Context.resolve(url).pathRole {
        case .personalSkill, .projectSkill, .unscannedSkill,
             .personalCommand, .projectCommand,
             .personalRule, .projectRule, .unreadablePathsRule,
             .subagent, .unnamedSubagent:
            return true
        default:
            return false
        }
    }

    // MARK: - context

    /// The filesystem half of classification, resolved ONCE per document.
    ///
    /// Without this the classifier probes the disk on every keystroke — the
    /// package walk is up to 8 `fileExists` calls and the AGENTS.md branch
    /// reads a sibling file. Measured at 27–56 µs per keystroke, which is fine
    /// until the volume is slow, and free to avoid.
    struct Context {
        let url: URL
        let inPackage: Bool
        let agentsIsReached: Bool
        /// The role as far as the PATH determines it. Fixed for the life of the
        /// document — a path does not change while you type in the file.
        let pathRole: Role
        /// True only for the three roles whose sentence depends on frontmatter:
        /// rules read `paths:`, subagents read `name:`, skills take modifiers.
        let readsFrontmatter: Bool

        static func resolve(_ url: URL) -> Context {
            let inPkg = enclosingPackage(of: url) != nil
            let agents = url.lastPathComponent == "AGENTS.md" && claudeMdReaches(url)
            let role = classifyPath(url, inPackage: inPkg, agentsIsReached: agents)
            var needsFM = false
            switch role {
            case .personalSkill, .projectSkill, .unscannedSkill: needsFM = true
            case .personalRule, .projectRule, .unreadablePathsRule: needsFM = true
            case .subagent, .unnamedSubagent: needsFM = true
            default: needsFM = false
            }
            return Context(url: url, inPackage: inPkg, agentsIsReached: agents,
                           pathRole: role, readsFrontmatter: needsFM)
        }
    }

    // MARK: - the sentence

    /// The window subtitle, computed from a resolved context and the live
    /// buffer. PURE: no filesystem access, so it is safe on the keystroke path.
    static func subtitle(_ ctx: Context, text: String) -> String {
        // The common case: the path settles it and the buffer is never read.
        guard ctx.readsFrontmatter else { return sentence(ctx.pathRole) }
        let fm = Frontmatter(text)
        // The consequence here is about how the file is READ, which is what
        // this readout is for. It also has to REPLACE the frontmatter-derived
        // sentence rather than extend it: refine() sees no fields in a block
        // Claude Code never opens, so an agent file whose second line is
        // `name: reviewer` would otherwise read "no name: field, so Claude
        // Code skips it" — a false statement about the file, which is the one
        // thing this sentence must never make.
        if fm.misplaced { return displacedSentence(ctx.pathRole) }
        let base = sentence(refine(ctx.pathRole, fm: fm))
        guard !base.isEmpty else { return "" }
        return base + modifiers(for: ctx.url, fm: fm)
    }

    /// Claude Code reads frontmatter ONLY when the opening `---` is the file's
    /// first line. A blank line, a stray space or a BOM in front of it and the
    /// whole file — markers included — is content. Nothing reports this, and
    /// the file looks completely normal.
    static let displacedClause =
        " · frontmatter is not the first line, so Claude Code reads the whole file as content"

    private static func displacedSentence(_ role: Role) -> String {
        // Lead with the half the PATH still guarantees, then the consequence.
        switch role {
        case .personalSkill(let c): return "Personal skill · /\(c)" + displacedClause
        case .projectSkill(let c):  return "Project skill · /\(c)" + displacedClause
        case .unscannedSkill:       return sentence(.unscannedSkill) + displacedClause
        case .personalRule:         return "Personal rule" + displacedClause
        case .projectRule, .unreadablePathsRule: return "Project rule" + displacedClause
        case .subagent, .unnamedSubagent: return "Subagent" + displacedClause
        default: return sentence(role)
        }
    }

    /// The only frontmatter-dependent refinements. Everything else is path.
    private static func refine(_ role: Role, fm: Frontmatter) -> Role {
        switch role {
        case .personalRule, .projectRule, .unreadablePathsRule:
            let personal: Bool = { if case .personalRule = role { return true }; return false }()
            if fm.value("paths") != nil || fm.firstSequenceEntry("paths") != nil {
                guard let p = fm.firstSequenceEntry("paths"), !p.isEmpty else { return .unreadablePathsRule }
                return personal ? .personalRule(pattern: p) : .projectRule(pattern: p)
            }
            return personal ? .personalRule(pattern: nil) : .projectRule(pattern: nil)
        case .subagent, .unnamedSubagent:
            // classifyPath cannot read frontmatter, so it always yields
            // .unnamedSubagent and this is the ONLY place the name resolves.
            // An earlier refactor stripped this lookup, and every valid agent
            // file then asserted "no name: field, so Claude Code skips it" —
            // a false statement about the file, which is the one thing the
            // reach sentence must never make.
            if let n = fm.value("name"), !n.isEmpty { return .subagent(name: n) }
            return .unnamedSubagent
        default:
            return role
        }
    }

    /// Convenience for callers that are not on the keystroke path — tests, and
    /// anything that opens a file once.
    static func subtitle(for url: URL?, text: String) -> String {
        guard let url else { return "" }
        return subtitle(Context.resolve(url), text: text)
    }

    private static func sentence(_ role: Role) -> String {
        switch role {
        case .personalSkill(let c):   return "Personal skill · /\(c)"
        case .projectSkill(let c):    return "Project skill · /\(c)"
        case .unscannedSkill:         return "Not in a directory Claude Code scans for skills"
        case .packageSupport:         return "Supporting file · read only when the package names it"
        case .personalCommand(let n): return "Personal command · /\(n)"
        case .projectCommand(let n):  return "Project command · /\(n)"
        case .personalMemory:         return "Personal memory · read in every session, every project"
        case .projectMemory:          return "Project memory · read for any file in this folder or below"
        case .localMemory:            return "Local project memory · read for any file here or below"
        case .agentsRead:             return "Read through the CLAUDE.md beside it"
        case .agentsIgnored:          return "Claude Code reads CLAUDE.md, not AGENTS.md"
        case .personalRule(let p):
            return p.map { "Personal rule · read when Claude opens \($0)" }
                ?? "Personal rule · read in every session, every project"
        case .projectRule(let p):
            return p.map { "Project rule · read when Claude opens \($0)" }
                ?? "Project rule · read in every session in this project"
        case .unreadablePathsRule:    return "Project rule · read only for the paths it lists"
        case .subagent(let n):        return "Subagent · Claude delegates to \(n)"
        case .unnamedSubagent:        return "Subagent · no name: field, so Claude Code skips it"
        case .personalSettings:       return "Personal settings · read in every session"
        case .projectSettings:        return "Project settings · read for this project"
        case .unknown:                return ""
        }
    }

    /// Invocation modifiers apply to skills only — they are skill frontmatter
    /// fields and mean nothing elsewhere.
    private static func modifiers(for url: URL, fm: Frontmatter) -> String {
        guard url.lastPathComponent == "SKILL.md" else { return "" }
        let noModel = fm.flagIsTrue("disable-model-invocation")
        let noUser = fm.flagIsFalse("user-invocable")
        switch (noModel, noUser) {
        case (true, true):   return " · neither you nor Claude can invoke it"
        case (true, false):  return " · you invoke it, Claude can't"
        case (false, true):  return " · Claude invokes it, you can't"
        case (false, false): return ""
        }
    }

    // MARK: - classification

    private static var home: String { Paths.home }
    private static var claudeHome: String { home + "/.claude" }

    static func classify(_ url: URL, text: String) -> Role {
        classify(Context.resolve(url), text: text)
    }

    static func classify(_ ctx: Context, text: String) -> Role {
        refine(ctx.pathRole, fm: Frontmatter(text))
    }

    private static func classifyPath(_ url: URL, inPackage: Bool, agentsIsReached: Bool) -> Role {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()

        // ---- skills -------------------------------------------------------
        if name == "SKILL.md" {
            // The command comes from the DIRECTORY name, never from `name:`.
            // That is the format's most misunderstood rule and the reason this
            // feature exists: rename the directory and the command changes;
            // edit `name:` and nothing moves.
            let dir = parent.lastPathComponent
            if parent.deletingLastPathComponent().path == claudeHome + "/skills" {
                return .personalSkill(command: dir)
            }
            if parent.deletingLastPathComponent().lastPathComponent == "skills",
               parent.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".claude" {
                return .projectSkill(command: dir)
            }
            return .unscannedSkill
        }

        // A file inside a package whose anchor is not itself.
        if inPackage { return .packageSupport }

        // ---- commands -----------------------------------------------------
        if url.pathExtension == "md", parent.lastPathComponent == "commands" {
            let base = url.deletingPathExtension().lastPathComponent
            if parent.path == claudeHome + "/commands" { return .personalCommand(name: base) }
            if parent.deletingLastPathComponent().lastPathComponent == ".claude" {
                return .projectCommand(name: base)
            }
        }

        // ---- memory -------------------------------------------------------
        if name == "CLAUDE.md" {
            return path == claudeHome + "/CLAUDE.md" ? .personalMemory : .projectMemory
        }
        if name == "CLAUDE.local.md" { return .localMemory }
        if name == "AGENTS.md" {
            return agentsIsReached ? .agentsRead : .agentsIgnored
        }

        // ---- rules --------------------------------------------------------
        if url.pathExtension == "md", let rulesRoot = ancestor(of: url, named: "rules"),
           rulesRoot.deletingLastPathComponent().lastPathComponent == ".claude"
            || rulesRoot.path == claudeHome + "/rules" {
            let personal = rulesRoot.path == claudeHome + "/rules"
            return personal ? .personalRule(pattern: nil) : .projectRule(pattern: nil)
        }

        // ---- subagents ----------------------------------------------------
        if url.pathExtension == "md", let agentsRoot = ancestor(of: url, named: "agents"),
           agentsRoot.deletingLastPathComponent().lastPathComponent == ".claude" {
            return .unnamedSubagent
        }

        // ---- settings -----------------------------------------------------
        if name == "settings.json" {
            if path == claudeHome + "/settings.json" { return .personalSettings }
            if parent.lastPathComponent == ".claude" { return .projectSettings }
        }

        return .unknown
    }

    // MARK: - helpers

    /// The nearest ancestor directory holding a SKILL.md, when the file itself
    /// is not that SKILL.md. Bounded so a deep path cannot walk to /.
    static func enclosingPackage(of url: URL) -> URL? {
        // A SKILL.md is its package's anchor, not a file inside one. Without
        // this guard every SKILL.md reports as its own supporting file.
        if url.lastPathComponent == "SKILL.md" { return nil }
        var dir = url.deletingLastPathComponent()
        var hops = 0
        while hops < 8, dir.path.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
            hops += 1
        }
        return nil
    }

    private static func ancestor(of url: URL, named target: String) -> URL? {
        var dir = url.deletingLastPathComponent()
        var hops = 0
        while hops < 8, dir.path.count > 1 {
            if dir.lastPathComponent == target { return dir }
            dir = dir.deletingLastPathComponent()
            hops += 1
        }
        return nil
    }

    /// Claude Code reads CLAUDE.md, not AGENTS.md — unless the CLAUDE.md beside
    /// it is a symlink to it, or imports it with @path.
    private static func claudeMdReaches(_ agents: URL) -> Bool {
        let sibling = agents.deletingLastPathComponent().appendingPathComponent("CLAUDE.md")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sibling.path) else { return false }
        if let dest = try? fm.destinationOfSymbolicLink(atPath: sibling.path),
           dest.hasSuffix("AGENTS.md") { return true }
        guard let body = try? String(contentsOf: sibling, encoding: .utf8) else { return false }
        return body.contains("@AGENTS.md") || body.contains("@./AGENTS.md")
    }
}
