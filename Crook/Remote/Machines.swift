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
        guard let text = try? String(contentsOfFile: Paths.home + "/.ssh/config", encoding: .utf8)
        else { return [] }
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("host ") else { continue }
            for name in t.dropFirst(5).split(separator: " ") {
                let n = String(name)
                // Wildcards are patterns, not machines.
                if n.contains("*") || n.contains("?") { continue }
                out.append(n)
            }
        }
        return Array(NSOrderedSet(array: out)).compactMap { $0 as? String }
    }

    // MARK: - the live connection

    private(set) var remote: RemoteProvider?

    /// Connect, install the helper if needed, and point the app at the result.
    ///
    /// Runs off the main thread: probing, installing and starting the session
    /// are all network work, and a spinner that cannot spin is worse than a
    /// wait. The completion lands back on main.
    func connect(host: String, passphrase: String? = nil,
                 completion: @escaping (Result<RemoteProvider, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let t = SSHTransport(host: host)
            do {
                try t.connect(passphrase: passphrase)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let p = RemoteProvider(transport: t, displayName: host)
            p.homePathDidResolve(t.remoteHome)
            // Only ever the two places Claude Code reads from, plus whatever
            // projects the user later adds.
            p.declareRoots([t.remoteHome + "/.claude"])
            p.roots = [t.remoteHome + "/.claude"]
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
