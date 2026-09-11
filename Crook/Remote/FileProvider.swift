import Foundation

/// One entry in a tree, from whichever machine owns it.
///
/// Deliberately flat and value-typed. The local provider fills this from a
/// directory listing; the remote one fills it from a snapshot the agent sent in
/// a single reply. Everything downstream builds nodes from these and cannot
/// tell the difference.
struct FSEntry {
    let path: String
    let isDirectory: Bool
    let mtime: Double
    let size: Int
    /// Line count, when the owning machine already knows it.
    ///
    /// The remote agent counts lines while it walks, because it is sitting on
    /// the disk and the walk is local to it. That one field removes an entire
    /// class of work from this side: without it, every changed file would need
    /// a round trip before its `+7` could be drawn. Locally it stays nil and
    /// SeenStore counts lines the way it always has.
    let lines: Int?

    init(path: String, isDirectory: Bool, mtime: Double, size: Int, lines: Int? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.mtime = mtime
        self.size = size
        self.lines = lines
    }
}

enum ProviderError: Error, LocalizedError {
    case notConnected(String)
    case unreadable(String)
    case unwritable(String, String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let m): return "Not connected to \(m)."
        case .unreadable(let p):   return "Could not read \(p)."
        case .unwritable(let p, let why): return "Could not write \(p): \(why)."
        }
    }
}

/// Everything Crook needs from a filesystem, and nothing more.
///
/// The whole point of this protocol is how small it is. Crook's filesystem
/// surface turned out to be seven files and about twenty-eight call sites,
/// which collapse to the handful below — and that is what makes talking to
/// another machine a feature rather than a rewrite.
///
/// The methods are synchronous on purpose. Making the whole app async to
/// accommodate a network would push latency into the typing path and into
/// every AppKit callback. Instead the remote provider answers these from a
/// snapshot it keeps in memory and refreshes in the background, which is what
/// a responsive UI needs regardless of where the bytes live. The only
/// genuinely blocking operations are reading and writing a document the user
/// asked for, and those already sit behind completion handlers.
protocol FileProvider: AnyObject {
    /// Stable identity. Used to key remembered state, so two machines holding
    /// the same path do not collide.
    var id: String { get }
    /// What the user calls this machine.
    var displayName: String { get }
    /// The home directory of the machine that owns these files. Reach
    /// classification is home-relative shape matching, so asking the wrong
    /// machine produces confidently wrong sentences.
    var homePath: String { get }
    var isLocal: Bool { get }
    var isConnected: Bool { get }

    func list(_ path: String) -> [FSEntry]
    func exists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    /// mtime and size without reading the file. The cheap change signal.
    func fingerprint(_ path: String) -> (mtime: Double, size: Int)?
    func contents(_ path: String) -> Data?
    func write(_ data: Data, to path: String) throws
    /// Where a symlink points, unresolved. Needed because a CLAUDE.md that is a
    /// symlink to AGENTS.md changes what Claude Code actually reads, and that
    /// link exists on the owning machine, not this one.
    func symlinkDestination(_ path: String) -> String?
    /// Answer many existence questions at once.
    ///
    /// Locally this is pointless and does nothing. Across a link it is the
    /// difference between one round trip and one per path, which is why it is
    /// on the protocol rather than behind a cast: the callers that benefit
    /// should not have to know which kind of provider they hold.
    func prefetchExistence(_ paths: [String])
}

extension FileProvider {
    /// Nothing to gain when the disk is right here.
    func prefetchExistence(_ paths: [String]) {}

    var claudePath: String { homePath + "/.claude" }
    var claudeURL: URL { URL(fileURLWithPath: claudePath) }
}

// MARK: - local

/// The machine Crook is running on. This is exactly what the app did before the
/// protocol existed, moved behind it unchanged — which is the point: the seam
/// had to be provably free at the local end before anything network was built.
final class LocalProvider: FileProvider {

    let id = "local"
    var displayName: String { "This Mac" }
    var homePath: String { Paths.home }
    let isLocal = true
    let isConnected = true

    func list(_ path: String) -> [FSEntry] {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        ) else { return [] }
        return entries.map { e in
            let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            return FSEntry(
                path: e.path,
                isDirectory: v?.isDirectory ?? false,
                mtime: (v?.contentModificationDate ?? .distantPast).timeIntervalSince1970,
                size: v?.fileSize ?? 0
            )
        }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// lstat rather than URLResourceValues: measured 0.368 ms against 297 ms
    /// across the fixture, because resourceValues faults in dataless iCloud
    /// placeholders. Those are skipped entirely — materialising a file from the
    /// cloud to draw a number in the rail would be an outrageous trade.
    func fingerprint(_ path: String) -> (mtime: Double, size: Int)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        if st.st_flags & UInt32(SF_DATALESS) != 0 { return nil }
        return (Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                Int(st.st_size))
    }

    func contents(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// Writes through a symlink to the file it names, keeping that file's
    /// permissions and extended attributes.
    ///
    /// CLAUDE.md is often a link to AGENTS.md. A plain atomic write renames a
    /// new file over the path it is given — the link itself — so the link
    /// became a regular file and the two names silently diverged. Replacing
    /// the resolved file keeps the link, and replaceItemAt carries the old
    /// file's metadata over to the new bytes. The new bytes are staged in the
    /// system's replacement directory for that volume, never in the project.
    func write(_ data: Data, to path: String) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            try data.write(to: target, options: .atomic)
            return
        }
        // A folder is never replaced by a file, whatever link led here.
        guard !isDirectory.boolValue else { throw CocoaError(.fileWriteInvalidFileName) }
        let before = try? fm.attributesOfItem(atPath: target.path)
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent)
        try data.write(to: staged)
        _ = try fm.replaceItemAt(target, withItemAt: staged)
        // The swap keeps extended attributes, but gives the file the staging
        // folder's group and the permissions that group allows. A file shared
        // through a group (anything in /Users/Shared) keeps both.
        // One at a time: a group this user isn't in fails alone, and the
        // permissions are still put back.
        if let group = before?[.groupOwnerAccountID] {
            try? fm.setAttributes([.groupOwnerAccountID: group], ofItemAtPath: target.path)
        }
        if let mode = before?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
    }

    func symlinkDestination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}

// MARK: - selection

/// Which machine this session is looking at.
///
/// One machine per window is the settled design, and Crook is a single-window
/// app, so a single current provider is the honest expression of that today.
/// When a second window arrives this moves onto the window controller; nothing
/// else has to change, because every consumer already asks for a provider
/// rather than reaching for FileManager.
enum Providers {
    static let local = LocalProvider()
    private(set) static var current: FileProvider = local

    static func use(_ p: FileProvider) { current = p }
    static func useLocal() { current = local }
}
