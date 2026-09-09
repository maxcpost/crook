import AppKit

/// The machines Crook knows about, and the one it is looking at.
///
/// A machine is remembered by the name you connect to — `mac-mini`, or whatever
/// alias is in ~/.ssh/config. Crook stores nothing else: no username, no key, no
/// passphrase. Everything about how to reach that name belongs to ssh, which
/// already knows, and duplicating it here would only create a second answer that
/// could disagree with the first.
final class Machines {

    static let shared = Machines()

    private let key = "CrookKnownMachines"
    private let lastKey = "CrookLastMachine"

    private(set) var known: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var last: String? {
        get { UserDefaults.standard.string(forKey: lastKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastKey) }
    }

    func remember(_ host: String) {
        var k = known.filter { $0 != host }
        k.insert(host, at: 0)
        known = Array(k.prefix(8))
    }

    func forget(_ host: String) {
        known = known.filter { $0 != host }
        if last == host { last = nil }
    }

    /// Host aliases from the user's own ssh config, offered as completions.
    /// Reading it is the difference between typing a hostname and remembering
    /// one.
    func sshConfigHosts() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        Self.collectHosts(from: Paths.home + "/.ssh/config", depth: 0, into: &out, seen: &seen)
        return out
    }

    /// One ssh config file, plus whatever it Includes.
    ///
    /// The grammar is looser than "Host name". The keyword is case-insensitive
    /// and may be followed by tabs or an `=` as well as spaces; one line can
    /// name several hosts; `!name` is a negation and `*` / `?` are patterns,
    /// none of them a machine. `Include` pulls in other files, relative to
    /// ~/.ssh and with globs — and a config split across config.d/ is where
    /// the aliases people actually use tend to live. The first version read
    /// "Host " followed by a space and nothing else, and offered `!bastion` as
    /// somewhere to connect.
    private static func collectHosts(from path: String, depth: Int,
                                     into out: inout [String], seen: inout Set<String>) {
        guard depth < 4, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let blank = CharacterSet(charactersIn: " \t")
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: blank)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (keyword, rest) = keywordAndArguments(line)
            let args = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch keyword.lowercased() {
            case "host":
                for n in args {
                    if n.hasPrefix("!") || n.contains("*") || n.contains("?") { continue }
                    if seen.insert(n).inserted { out.append(n) }
                }
            case "include":
                for pattern in args {
                    for file in included(pattern) {
                        collectHosts(from: file, depth: depth + 1, into: &out, seen: &seen)
                    }
                }
            default:
                continue
            }
        }
    }

    /// ssh_config: `keyword [=] arguments`. The keyword ends at the first
    /// space, tab or `=`.
    private static func keywordAndArguments(_ line: String) -> (String, String) {
        let blank = CharacterSet(charactersIn: " \t")
        var i = line.startIndex
        while i < line.endIndex, line[i] != " ", line[i] != "\t", line[i] != "=" {
            i = line.index(after: i)
        }
        var rest = String(line[i...]).trimmingCharacters(in: blank)
        if rest.hasPrefix("=") { rest = String(rest.dropFirst()).trimmingCharacters(in: blank) }
        return (String(line[..<i]), rest)
    }

    /// Files an Include pattern names. Relative paths are relative to ~/.ssh,
    /// as ssh resolves them for a user's own config.
    private static func included(_ pattern: String) -> [String] {
        var p = pattern
        if p.hasPrefix("~/") { p = Paths.home + p.dropFirst() }
        else if !p.hasPrefix("/") { p = Paths.home + "/.ssh/" + p }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(p, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    // MARK: - the live connection

    private(set) var remote: RemoteProvider?

    /// Connect, install the helper if needed, and point the app at the result.
    ///
    /// Runs off the main thread: probing, installing and starting the session
    /// are all network work, and a spinner that cannot spin is worse than a
    /// wait. The completion lands back on main.
    func connect(host: String, secret: String? = nil,
                 completion: @escaping (Result<RemoteProvider, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let t = SSHTransport(host: host)
            do {
                try t.connect(secret: secret)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let p = RemoteProvider(transport: t, displayName: host)
            p.homePathDidResolve(t.remoteHome)
            // The personal tree AND every project already imported for this
            // machine. Declaring only ~/.claude here is what made a project
            // added in an earlier session unopenable after a reconnect: the
            // agent refuses to read outside its roots, so the file was drawn in
            // the sidebar and did nothing when clicked.
            p.declareRoots(Workspace.remoteRoots(home: t.remoteHome, providerID: p.id))
            DispatchQueue.main.async {
                self.remote = p
                self.remember(host)
                self.last = host
                completion(.success(p))
            }
        }
    }

    func disconnect() {
        remote?.transport.disconnect()
        remote = nil
        Providers.useLocal()
    }
}
