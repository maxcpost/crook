import Foundation

/// Another Mac's files, behind the same protocol as this one's.
///
/// The tree arrives in a single reply and is held in memory; every synchronous
/// question the UI asks is answered from that snapshot. This is not a cache in
/// the optimisation sense — it is what makes the app usable at all. Answering
/// `list()` with a round trip would mean one per directory during a rail
/// rebuild, and the rail rebuilds whenever Crook comes forward.
///
/// Only three things genuinely go to the wire on demand: reading a document the
/// user opened, writing one they saved, and stat-ing a path that is not in the
/// tree — which happens for the absolute links Crook checks inside files, and
/// for project candidates decoded from Claude Code's own slugs.
final class RemoteProvider: FileProvider {

    let transport: SSHTransport
    let id: String
    let displayName: String
    private(set) var homePath: String
    var isLocal: Bool { false }
    var isConnected: Bool { transport.isRunning }

    /// Everything under the roots, flat.
    private var entries: [String: FSEntry] = [:]
    /// Directory path -> the paths directly inside it. Built once per refresh so
    /// `list()` is a dictionary lookup rather than a scan of every entry.
    private var children: [String: [String]] = [:]
    /// Answers for paths outside the tree. Cleared on every refresh, because a
    /// remembered "no" would outlive the thing that made it true.
    private var statCache: [String: FSEntry?] = [:]
    private let lock = NSLock()

    var roots: [String] = []

    /// The handshake arrives before this object exists, so the home is set once
    /// immediately after construction rather than being read at init time —
    /// where it would have captured an empty string.
    func homePathDidResolve(_ home: String) { homePath = home }
    var onTreeChanged: (() -> Void)?
    var onDisconnected: ((String) -> Void)?

    init(transport: SSHTransport, displayName: String) {
        self.transport = transport
        self.id = "ssh:\(transport.host)"
        self.displayName = displayName
        self.homePath = transport.remoteHome
        transport.onEvent = { [weak self] ev in self?.handle(ev) }
        transport.onClosed = { [weak self] in
            guard let self else { return }
            self.onDisconnected?("Lost the connection to \(self.displayName).")
        }
    }

    private func handle(_ ev: [String: Any]) {
        switch ev["ev"] as? String {
        case "changed":
            // Coalesced by the agent already; a rebuild is cheap because the
            // snapshot refresh is one round trip.
            refresh { }
        default:
            break
        }
    }

    // MARK: - snapshot

    /// Pull the whole tree. One request, one reply.
    func refresh(_ done: @escaping () -> Void) {
        let rootList = roots
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let reply = try? self.transport.send(["op": "tree", "roots": rootList], timeout: 30),
                  let rows = reply["rows"] as? [[Any]] else {
                DispatchQueue.main.async { done() }
                return
            }
            var e: [String: FSEntry] = [:]
            var kids: [String: [String]] = [:]
            e.reserveCapacity(rows.count)
            for r in rows where r.count >= 5 {
                guard let path = r[0] as? String,
                      let isDir = r[1] as? Bool,
                      let mtime = r[2] as? Double,
                      let size = r[3] as? Int else { continue }
                e[path] = FSEntry(path: path, isDirectory: isDir, mtime: mtime,
                                  size: size, lines: r[4] as? Int)
                let parent = (path as NSString).deletingLastPathComponent
                kids[parent, default: []].append(path)
            }
            self.lock.lock()
            self.entries = e
            self.children = kids
            self.statCache.removeAll()
            self.lock.unlock()
            DispatchQueue.main.async {
                self.onTreeChanged?()
                done()
            }
        }
    }

    /// Ask the agent to stream change events for the roots.
    func startWatching() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = try? self.transport.send(["op": "watch", "roots": self.roots], timeout: 10)
        }
    }

    /// Bound what the agent will serve. Not a privilege boundary — it runs as
    /// the same user either way — but it keeps a client-side bug from reaching
    /// the whole disk.
    func declareRoots(_ paths: [String]) {
        roots = paths
        _ = try? transport.send(["op": "roots", "paths": paths], timeout: 10)
    }

    // MARK: - FileProvider

    func list(_ path: String) -> [FSEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let kids = children[path] else { return [] }
        return kids.compactMap { entries[$0] }
    }

    func exists(_ path: String) -> Bool {
        if let e = lookup(path) { return e != nil }
        return stat(path) != nil
    }

    func isDirectory(_ path: String) -> Bool {
        if let e = lookup(path) { return e?.isDirectory ?? false }
        return stat(path)?.isDirectory ?? false
    }

    func fingerprint(_ path: String) -> (mtime: Double, size: Int)? {
        let e = lookup(path).flatMap { $0 } ?? stat(path)
        guard let e else { return nil }
        return (e.mtime, e.size)
    }

    func contents(_ path: String) -> Data? {
        guard let reply = try? transport.send(["op": "read", "path": path], timeout: 30),
              reply["ok"] as? Bool == true,
              let b64 = reply["b64"] as? String else { return nil }
        return Data(base64Encoded: b64)
    }

    func write(_ data: Data, to path: String) throws {
        let reply = try transport.send(
            ["op": "write", "path": path, "b64": data.base64EncodedString()], timeout: 60)
        guard reply["ok"] as? Bool == true else {
            throw ProviderError.unwritable(path, reply["error"] as? String ?? "refused")
        }
    }

    func symlinkDestination(_ path: String) -> String? {
        guard let reply = try? transport.send(["op": "symlink", "path": path], timeout: 10) else { return nil }
        return reply["dest"] as? String
    }

    // MARK: - lookups

    /// Double optional on purpose: the outer says whether the snapshot knows
    /// about this path at all, the inner whether it exists. Collapsing them
    /// would make "not in the tree" indistinguishable from "not on the disk",
    /// and Crook would report live files as dead.
    private func lookup(_ path: String) -> FSEntry?? {
        lock.lock(); defer { lock.unlock() }
        if let e = entries[path] { return .some(e) }
        if let c = statCache[path] { return .some(c) }
        // Inside a known directory but absent from it: genuinely not there.
        let parent = (path as NSString).deletingLastPathComponent
        if children[parent] != nil { return .some(nil) }
        return nil
    }

    private func stat(_ path: String) -> FSEntry? {
        guard let reply = try? transport.send(["op": "stat", "paths": [path]], timeout: 8),
              let stats = reply["stats"] as? [[Any]], let row = stats.first, row.count >= 5
        else { return nil }
        let found = row[1] as? Bool ?? false
        let e: FSEntry? = found
            ? FSEntry(path: path, isDirectory: row[2] as? Bool ?? false,
                      mtime: row[3] as? Double ?? 0, size: row[4] as? Int ?? 0)
            : nil
        lock.lock(); statCache[path] = e; lock.unlock()
        return e
    }

    /// Answer many paths in one round trip. Dead-path scanning asks about a
    /// whole document's worth of links at once, and asking one at a time is
    /// what would make this unusable over a link.
    func prefetchExistence(_ paths: [String]) {
        let unknown = paths.filter { lookup($0) == nil }
        guard !unknown.isEmpty else { return }
        guard let reply = try? transport.send(["op": "stat", "paths": unknown], timeout: 20),
              let stats = reply["stats"] as? [[Any]] else { return }
        lock.lock()
        for row in stats where row.count >= 5 {
            guard let p = row[0] as? String else { continue }
            statCache[p] = (row[1] as? Bool ?? false)
                ? FSEntry(path: p, isDirectory: row[2] as? Bool ?? false,
                          mtime: row[3] as? Double ?? 0, size: row[4] as? Int ?? 0)
                : nil
        }
        lock.unlock()
    }
}
