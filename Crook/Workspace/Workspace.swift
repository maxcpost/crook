import Foundation

/// What Crook shows in the rail.
///
/// Two top-level sections, per the user's instruction:
///   SYSTEM   — the blanket Claude files at ~/.claude that apply everywhere
///   PROJECTS — projects using Claude Code, each expanding to its own tree
///
/// Only files Claude Code actually reads are listed. A project directory is not
/// a repo browser: everything that is not a Claude file is invisible.
final class Workspace {

    static let shared = Workspace()

    private(set) var system: [Node] = []
    private(set) var projects: [Node] = []
    /// The two section roots. The rail renders these, and window titles are
    /// derived from them, so a breadcrumb can never disagree with the tree.
    private(set) var roots: [Node] = []

    /// Projects are remembered PER MACHINE.
    ///
    /// A path only means something on the machine it lives on, and the mini's
    /// projects appearing in the local sidebar as broken entries would be worse
    /// than useless. The unsuffixed key is this Mac's, so everything imported
    /// before machines existed keeps working untouched.
    private var defaultsKey: String {
        let p = Providers.current
        return p.isLocal ? "CrookImportedProjects" : Self.importedKey(forProviderID: p.id)
    }

    static func importedKey(forProviderID id: String) -> String { "CrookImportedProjects::\(id)" }

    // MARK: - node

    final class Node {
        enum Kind { case section, project, package, folder, file, action }
        let kind: Kind
        let name: String
        let url: URL?
        var children: [Node]
        /// Line count, shown right-aligned. nil for containers.
        var lines: Int?
        /// Signed line delta since this file was last opened, when the agent
        /// rewrote it in between. nil means show nothing.
        var delta: Int?
        weak var parent: Node?

        init(kind: Kind, name: String, url: URL? = nil, children: [Node] = [], lines: Int? = nil) {
            self.kind = kind
            self.name = name
            self.url = url
            self.children = children
            self.lines = lines
            for c in children { c.parent = self }
        }

        var isExpandable: Bool { !children.isEmpty }
    }

    // MARK: - what counts as a Claude file

    /// Directories never descended into, anywhere. Inside an imported project the
    /// blast radius is one folder the user chose, but one real project contains
    /// four vendored Playwright SKILL.md files under node_modules.
    static let excludedDirs: Set<String> = [
        "node_modules", ".venv", "venv", "site-packages", ".git", "dist", "build",
        ".next", ".pytest_cache", ".obsidian", "__pycache__", ".mypy_cache",
        ".ruff_cache", ".tox", "Pods", "DerivedData", ".build",
    ]

    /// Machine state under ~/.claude that is never authored by hand.
    static let excludedSystemDirs: Set<String> = [
        "plugins", "sessions", "tasks", "jobs", "telemetry", "file-history",
        "paste-cache", "shell-snapshots", "backups", "cache", "downloads",
        "statsig", "ide", "todos",
    ]

    static func isClaudeFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "settings.local.json" { return false }   // machine-written exhaust
        if name == "settings.json" { return true }
        // Project-scoped MCP server config. Hand-written, committed to git, and
        // the file that keeps two machines configured identically — squarely a
        // file that steers Claude. ~/.claude.json is deliberately NOT here: it
        // is machine-written state, excluded for the same reason
        // settings.local.json is.
        if name == ".mcp.json" { return true }
        if name == "CLAUDE.md" || name == "AGENTS.md" || name == "MEMORY.md" { return true }
        if name == "SKILL.md" || name == "README.md" || name == "CURATION.md" { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    // MARK: - building

    func reload() {
        system = buildSystem()
        projects = importedURLs().compactMap { buildProject(at: $0) }
        let addRow = Node(kind: .action, name: "Add Project…")
        roots = [
            Node(kind: .section, name: "SYSTEM", children: system),
            Node(kind: .section, name: "PROJECTS", children: projects + [addRow]),
        ]
    }

    /// The full path to a file as it appears in the rail, rooted at "System" or
    /// at the project name — never a bare parent folder. A file four levels
    /// deep needs all four; "Notes ▸ x.md" does not say which Notes.
    func breadcrumb(for url: URL) -> [String] {
        guard let node = findNode(matching: url) else { return [] }

        var chain: [String] = []
        var cursor: Node? = node
        while let n = cursor, n.kind != .section {
            chain.append(n.name)
            cursor = n.parent
        }
        // cursor is now the section, if the node was inside one.
        if let section = cursor, section.kind == .section {
            // Projects are named by their own root; the section label adds
            // nothing. System files carry the scope explicitly.
            if section.name == "SYSTEM" { chain.append("System") }
        }
        return chain.reversed()
    }

    private func findNode(matching url: URL) -> Node? {
        func search(_ n: Node) -> Node? {
            if n.url == url && n.kind == .file { return n }
            for c in n.children { if let hit = search(c) { return hit } }
            return nil
        }
        for r in roots { if let hit = search(r) { return hit } }
        return nil
    }

    /// ~/.claude on whichever machine this window is looking at.
    private var claudeHome: URL {
        Providers.current.claudeURL
    }

    /// ~/.claude — skills, commands, agents, settings.json, and the memory nodes
    /// under projects/*/memory (the transcripts beside them are excluded).
    private func buildSystem() -> [Node] {
        let p = Providers.current
        let home = claudeHome
        var out: [Node] = []

        for sub in ["skills", "commands", "agents"] {
            let dir = home.appendingPathComponent(sub)
            guard p.exists(dir.path) else { continue }
            let kids = scan(dir, depth: 0)
            if !kids.isEmpty {
                out.append(Node(kind: .folder, name: sub, url: dir, children: kids))
            }
        }

        let settings = home.appendingPathComponent("settings.json")
        if p.exists(settings.path) {
            let n = Node(kind: .file, name: "settings.json", url: settings)
            n.delta = SeenStore.shared.delta(for: settings)
            out.append(n)
        }

        // ~/.claude/projects/**/memory/*.md only — the 1,794 transcript files
        // beside them are excluded (D-50).
        let projectsDir = home.appendingPathComponent("projects")
        var memoryNodes: [Node] = []
        let projectEntries = p.list(projectsDir.path).map { URL(fileURLWithPath: $0.path) }
        if !projectEntries.isEmpty {
            for e in projectEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let mem = e.appendingPathComponent("memory")
                guard p.exists(mem.path) else { continue }
                let kids = scan(mem, depth: 0)
                guard !kids.isEmpty else { continue }
                memoryNodes.append(Node(kind: .folder,
                                        name: prettySlug(e.lastPathComponent),
                                        url: mem, children: kids))
            }
        }
        if !memoryNodes.isEmpty {
            out.append(Node(kind: .folder, name: "memory", url: projectsDir, children: memoryNodes))
        }

        return out
    }

    /// A project expands to only the Claude files inside it.
    func buildProject(at root: URL) -> Node? {
        let p = Providers.current
        guard p.isDirectory(root.path) else { return nil }

        var kids: [Node] = []

        // .mcp.json sits here too: project-scoped MCP servers, committed to git.
        for top in ["CLAUDE.md", "AGENTS.md", ".mcp.json"] {
            let u = root.appendingPathComponent(top)
            if p.exists(u.path) {
                let n = Node(kind: .file, name: top, url: u)
                n.delta = SeenStore.shared.delta(for: u)
                kids.append(n)
            }
        }

        let dotClaude = root.appendingPathComponent(".claude")
        if p.exists(dotClaude.path) {
            let inner = scan(dotClaude, depth: 0)
            if !inner.isEmpty {
                kids.append(Node(kind: .folder, name: ".claude", url: dotClaude, children: inner))
            }
        }

        // A memory directory the project points Claude at, plus loose SKILL.md
        // packages living outside .claude, which is where most of them live in
        // practice. "brain" used to be in this list; it was a leftover from a
        // cut feature and matched no real directory.
        for extra in ["memory", "skills"] {
            let u = root.appendingPathComponent(extra)
            guard p.exists(u.path), !kids.contains(where: { $0.url == u }) else { continue }
            let inner = scan(u, depth: 0)
            if !inner.isEmpty {
                kids.append(Node(kind: .folder, name: extra, url: u, children: inner))
            }
        }

        guard !kids.isEmpty else {
            return Node(kind: .project, name: root.lastPathComponent, url: root, children: [])
        }
        return Node(kind: .project, name: root.lastPathComponent, url: root, children: kids)
    }

    /// The only hidden entries Crook will descend into or show. `.claude` is
    /// reached explicitly elsewhere, but a nested one has to survive the filter.
    static let visibleDotfiles: Set<String> = [".claude", ".mcp.json"]

    /// Recursive scan, Claude files only, excluded directories never entered.
    private func scan(_ dir: URL, depth: Int) -> [Node] {
        guard depth < 6 else { return [] }
        // The listing carries isDirectory, so this walk costs one call per
        // directory rather than one per entry — which is what makes it viable
        // when the directory is on another machine.
        let listing = Providers.current.list(dir.path)
        guard !listing.isEmpty else { return [] }

        var folders: [Node] = []
        var files: [Node] = []

        for entry in listing.sorted(by: { ($0.path as NSString).lastPathComponent.localizedStandardCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }) {
            let e = URL(fileURLWithPath: entry.path)
            let leaf = e.lastPathComponent
            // Everything hidden stays hidden except the handful Claude reads.
            if leaf.hasPrefix("."), !Self.visibleDotfiles.contains(leaf) { continue }
            if entry.isDirectory {
                if Self.excludedDirs.contains(e.lastPathComponent) { continue }
                if dir == claudeHome && Self.excludedSystemDirs.contains(e.lastPathComponent) { continue }
                let kids = scan(e, depth: depth + 1)
                if !kids.isEmpty {
                    let isPackage = kids.contains { $0.name == "SKILL.md" }
                    folders.append(Node(kind: isPackage ? .package : .folder,
                                        name: e.lastPathComponent, url: e, children: kids))
                }
            } else if Self.isClaudeFile(e) {
                let n = Node(kind: .file, name: e.lastPathComponent, url: e)
                n.delta = SeenStore.shared.delta(for: e)
                files.append(n)
            }
        }
        // SKILL.md first inside a package, then the rest.
        files.sort { a, b in
            if a.name == "SKILL.md" { return true }
            if b.name == "SKILL.md" { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return folders + files
    }

    /// Resolve a slug against the filesystem, joining hyphenated components
    /// back together when the split form does not exist.
    static func decodeSlug(_ slug: String) -> String? {
        let parts = slug.dropFirst().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let p = Providers.current

        // One `exists` answer per distinct candidate. Backtracking revisits
        // prefixes, and over a link each of those is a round trip.
        //
        // And a budget, because over a link the worst case is the one that
        // matters. A slug whose project was deleted resolves nowhere, and an
        // unbounded search then tries every way of re-joining the remaining
        // components — quadratic in their number, each try a stat on the far
        // machine, all before the picker can draw. Twice the components plus a
        // few covers the shortest-first walk and the decoy case it exists for;
        // anything needing more is a stale slug, whose right answer is nil.
        var known: [String: Bool] = [:]
        var probes = 0
        let budget = parts.count * 2 + 4
        func exists(_ path: String) -> Bool {
            if let k = known[path] { return k }
            guard probes < budget else { return false }
            probes += 1
            let v = p.exists(path)
            known[path] = v
            return v
        }

        // Taking the first component that exists is not enough, because a
        // shorter one existing does not mean it is the right one. A project at
        // …/T/crook-slug-1 sits beside a directory called …/T/crook, and the
        // greedy walk took `crook`, then failed on the rest and returned nil —
        // the project simply vanished from the picker. Any name that extends a
        // real sibling does this: `atlas` beside `atlas-relay`, `web` beside
        // `web-ui`. So try the shortest match first, and if the REMAINDER
        // cannot be resolved, come back and take a longer one.
        func walk(_ prefix: String, _ i: Int) -> String? {
            guard i < parts.count else { return prefix.isEmpty ? nil : prefix }
            var candidate = prefix + "/" + parts[i]
            var j = i
            while true {
                if exists(candidate), let done = walk(candidate, j + 1) { return done }
                guard j + 1 < parts.count else { return nil }
                j += 1
                candidate += "-" + parts[j]
            }
        }
        return walk("", 0)
    }

    private func prettySlug(_ slug: String) -> String {
        // Resolve properly so a hyphenated folder is not truncated to its tail.
        if let p = Self.decodeSlug(slug) {
            return (p as NSString).lastPathComponent
        }
        return slug.split(separator: "-").last.map(String.init) ?? slug
    }

    /// The container a file belongs to, for disambiguating a filename that is
    /// shared by dozens of files: the enclosing skill package if there is one,
    /// otherwise the imported project, otherwise the parent directory.
    func contextLabel(for url: URL) -> String? {
        let p = Providers.current

        // Nearest ancestor holding a SKILL.md — the package is the unit of work.
        var dir = url.deletingLastPathComponent()
        var hops = 0
        while hops < 6, dir.path.count > 1 {
            if p.exists(dir.appendingPathComponent("SKILL.md").path) {
                return dir.lastPathComponent
            }
            dir = dir.deletingLastPathComponent()
            hops += 1
        }

        // Otherwise the imported project that contains it.
        for root in importedURLs() where url.path.hasPrefix(root.path + "/") {
            return root.lastPathComponent
        }

        // ~/.claude/projects/<slug>/memory/x.md -> the project name.
        let home = claudeHome.appendingPathComponent("projects").path
        if url.path.hasPrefix(home + "/") {
            let rest = url.path.dropFirst(home.count + 1)
            if let slug = rest.split(separator: "/").first {
                return prettySlug(String(slug))
            }
        }

        if url.path.hasPrefix(claudeHome.path + "/") { return "System" }

        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? nil : parent
    }

    // MARK: - imported projects (D-56: imported, never discovered)

    func importedURLs() -> [URL] {
        (UserDefaults.standard.array(forKey: defaultsKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    /// The projects imported for a named machine, without needing that machine
    /// to be the current one.
    ///
    /// `defaultsKey` reads Providers.current, which is still the local provider
    /// while a connection is being established — the exact moment the roots
    /// have to be computed.
    static func importedPaths(forProviderID id: String) -> [String] {
        UserDefaults.standard.array(forKey: importedKey(forProviderID: id)) as? [String] ?? []
    }

    /// Everything the agent on `providerID` is allowed to serve.
    ///
    /// There is one correct answer — the personal tree plus every project this
    /// machine has imported — and it was being assembled twice, from two
    /// momentary lists. On connect it was `~/.claude` alone, dropping every
    /// project imported in an earlier session; on add it was `~/.claude` plus
    /// only the projects picked in that sheet, dropping the ones picked before.
    ///
    /// Either way the sidebar kept drawing the files, because `exists` falls
    /// back to a `stat` the agent does not gate, while `read` is gated. The
    /// result was a file you could see and could not open, and no error told
    /// you why.
    static func remoteRoots(home: String, providerID: String) -> [String] {
        var seen = Set<String>()
        return ([home + "/.claude"] + importedPaths(forProviderID: providerID))
            .filter { seen.insert($0).inserted }
    }

    func addProject(_ url: URL) {
        var paths = importedURLs().map(\.path)
        guard !paths.contains(url.path) else { return }
        paths.append(url.path)
        UserDefaults.standard.set(paths, forKey: defaultsKey)
        reload()
    }

    func removeProject(_ url: URL) {
        let paths = importedURLs().map(\.path).filter { $0 != url.path }
        UserDefaults.standard.set(paths, forKey: defaultsKey)
        reload()
    }

    /// Suggestions for the import picker, drawn from the directories Claude Code
    /// already maintains. Suggestions only — nothing enters unchosen (D-56).
    func suggestions() -> [URL] {
        let p = Providers.current
        let dir = claudeHome.appendingPathComponent("projects")
        let entries = p.list(dir.path)
        guard !entries.isEmpty else { return [] }
        let imported = Set(importedURLs().map(\.path))

        // Every candidate needs an isDirectory answer, and over a link that is
        // one round trip each — thirty slugs would be thirty waits. Ask once.
        p.prefetchExistence(entries.compactMap { e -> String? in
            let slug = (e.path as NSString).lastPathComponent
            guard slug.hasPrefix("-") else { return nil }
            return Self.decodeSlug(slug) ?? slug.replacingOccurrences(of: "-", with: "/")
        })
        return entries.compactMap { entry -> (URL, Date)? in
            let e = URL(fileURLWithPath: entry.path)
            // slug -Users-max-Documents-Foo  ->  /Users/max/Documents/Foo
            // Claude Code slugs a path by replacing "/" with "-", which is
            // lossy: a directory called ab-cd is indistinguishable from
            // ab/cd. Walk the components and re-join greedily against the
            // filesystem instead of blindly swapping every hyphen, which
            // dropped every project whose name contains one.
            let slug = e.lastPathComponent
            guard slug.hasPrefix("-") else { return nil }
            let path = Self.decodeSlug(slug) ?? slug.replacingOccurrences(of: "-", with: "/")
            guard p.isDirectory(path) else { return nil }
            guard !imported.contains(path) else { return nil }
            return (URL(fileURLWithPath: path), Date(timeIntervalSince1970: entry.mtime))
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }
}
