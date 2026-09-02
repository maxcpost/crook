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

    private let defaultsKey = "CrookImportedProjects"

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

    private var claudeHome: URL {
        Paths.claudeURL
    }

    /// ~/.claude — skills, commands, agents, settings.json, and the memory nodes
    /// under projects/*/memory (the transcripts beside them are excluded).
    private func buildSystem() -> [Node] {
        let fm = FileManager.default
        let home = claudeHome
        var out: [Node] = []

        for sub in ["skills", "commands", "agents"] {
            let dir = home.appendingPathComponent(sub)
            guard fm.fileExists(atPath: dir.path) else { continue }
            let kids = scan(dir, depth: 0)
            if !kids.isEmpty {
                out.append(Node(kind: .folder, name: sub, url: dir, children: kids))
            }
        }

        let settings = home.appendingPathComponent("settings.json")
        if fm.fileExists(atPath: settings.path) {
            let n = Node(kind: .file, name: "settings.json", url: settings)
            n.delta = SeenStore.shared.delta(for: settings)
            out.append(n)
        }

        // ~/.claude/projects/**/memory/*.md only — the 1,794 transcript files
        // beside them are excluded (D-50).
        let projectsDir = home.appendingPathComponent("projects")
        var memoryNodes: [Node] = []
        if let entries = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
            for e in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let mem = e.appendingPathComponent("memory")
                guard fm.fileExists(atPath: mem.path) else { continue }
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
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        var kids: [Node] = []

        for top in ["CLAUDE.md", "AGENTS.md"] {
            let u = root.appendingPathComponent(top)
            if fm.fileExists(atPath: u.path) {
                let n = Node(kind: .file, name: top, url: u)
                n.delta = SeenStore.shared.delta(for: u)
                kids.append(n)
            }
        }

        let dotClaude = root.appendingPathComponent(".claude")
        if fm.fileExists(atPath: dotClaude.path) {
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
            guard fm.fileExists(atPath: u.path), !kids.contains(where: { $0.url == u }) else { continue }
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

    /// Recursive scan, Claude files only, excluded directories never entered.
    private func scan(_ dir: URL, depth: Int) -> [Node] {
        guard depth < 6 else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var folders: [Node] = []
        var files: [Node] = []

        for e in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
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
        var path = ""
        var i = 0
        let fm = FileManager.default
        while i < parts.count {
            var candidate = path + "/" + parts[i]
            var j = i
            // Extend with further "-"-joined components while nothing exists.
            while !fm.fileExists(atPath: candidate), j + 1 < parts.count {
                j += 1
                candidate += "-" + parts[j]
            }
            guard fm.fileExists(atPath: candidate) else { return nil }
            path = candidate
            i = j + 1
        }
        return path.isEmpty ? nil : path
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
        let fm = FileManager.default

        // Nearest ancestor holding a SKILL.md — the package is the unit of work.
        var dir = url.deletingLastPathComponent()
        var hops = 0
        while hops < 6, dir.path.count > 1 {
            if fm.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) {
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
        let dir = claudeHome.appendingPathComponent("projects")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let imported = Set(importedURLs().map(\.path))
        return entries.compactMap { e -> (URL, Date)? in
            // slug -Users-max-Documents-Foo  ->  /Users/max/Documents/Foo
            // Claude Code slugs a path by replacing "/" with "-", which is
            // lossy: a directory called ab-cd is indistinguishable from
            // ab/cd. Walk the components and re-join greedily against the
            // filesystem instead of blindly swapping every hyphen, which
            // dropped every project whose name contains one.
            let slug = e.lastPathComponent
            guard slug.hasPrefix("-") else { return nil }
            let path = Self.decodeSlug(slug) ?? slug.replacingOccurrences(of: "-", with: "/")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            guard !imported.contains(path) else { return nil }
            let d = (try? e.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (URL(fileURLWithPath: path), d)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }
}
