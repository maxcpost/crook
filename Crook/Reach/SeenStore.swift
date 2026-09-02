import Foundation
import CryptoKit

/// What the agent changed while you were somewhere else.
///
/// Claude Code wrote most of this corpus. The skill a vibe coder actually lacks
/// is not composition — there are no blank pages here — it is ratification:
/// reading a write you did not make and deciding to keep it. So the rail marks
/// files whose bytes changed on disk since you last had them open, with a
/// signed line delta.
///
/// This reintroduces the trailing figure that was removed from the rail for
/// reading as an unexplained number. `+7` beside a file the agent touched
/// explains itself in a way an absolute line count never did — that is the
/// whole justification for the glyph coming back.
///
/// Persisted state is deliberately tiny: one hash and one line count per file,
/// in the app's own container. NEVER a dotfile in the user's tree — Crook does
/// not write to the corpus it is watching.
final class SeenStore {

    static let shared = SeenStore()

    private struct Entry: Codable {
        var hash: UInt64
        var lines: Int
        var mtime: Double
    }

    /// Guards `entries`. markSeen writes on the main thread, delta reads there
    /// during every rail reload, and write()/prune() both run on a utility
    /// queue. Swift Dictionary is not thread-safe, and the three-second prune
    /// lands squarely in the window when the first files are being opened.
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let url: URL
    /// Where the last-opened CONTENT of each file lives. A hash tells you
    /// something moved; only the bytes let you show what.
    private let snapshots: URL
    private var dirty = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crook", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("seen.json")
        snapshots = base.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: url),
           let e = try? JSONDecoder().decode([String: Entry].self, from: d) {
            entries = e
        }
    }

    // MARK: - reading

    /// The signed line delta to show beside a file, or nil to show nothing.
    ///
    /// Nil in every uncertain case: never opened, unreadable, unchanged, and
    /// touched-but-byte-identical.
    ///
    /// A changed file whose line count did not move returns 0, NOT nil. 13.8%
    /// of real markdown rewrites change bytes without changing the line count,
    /// and silence there would hide the case most likely to matter — the agent
    /// rewrote a paragraph in place. "±0" says something happened.
    func delta(for url: URL) -> Int? {
        lock.lock()
        let prior0 = entries[url.path]
        lock.unlock()
        guard let prior = prior0 else { return nil }
        guard let m = mtime(url.path) else { return nil }
        if abs(m - prior.mtime) < 0.001 { return nil }   // untouched: no read, no hash
        guard let now = measure(url) else { return nil }
        if now.hash == prior.hash { return nil }         // touched, same bytes
        return now.lines - prior.lines
    }

    /// The rail glyph. U+2212 MINUS SIGN, never an ASCII hyphen: a hyphen in a
    /// tabular-figures column is a different width and the column stops lining
    /// up. Zero is signed so it reads as a measurement rather than an absence.
    static func format(_ d: Int) -> String {
        if d > 0 { return "+\(d)" }
        if d < 0 { return "\u{2212}\(-d)" }
        return "\u{00B1}0"
    }

    /// lstat rather than URLResourceValues: measured 0.368 ms vs 297 ms across
    /// the fixture, because resourceValues faults in dataless iCloud
    /// placeholders. SF_DATALESS files are skipped entirely — materialising one
    /// to draw a rail figure would be an outrageous trade.
    private func mtime(_ path: String) -> Double? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        if st.st_flags & UInt32(SF_DATALESS) != 0 { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    // MARK: - writing

    /// Called when a document is opened. Opening is the act of ratifying, and
    /// it must record EVERY time — reopening a file the agent has since
    /// rewritten has to clear its figure again.
    func markSeen(_ url: URL?) {
        guard let url, let m = measure(url) else { return }
        lock.lock(); entries[url.path] = m; dirty = true; lock.unlock()
        scheduleFlush()
        writeSnapshot(url)
    }

    // MARK: - snapshots

    private func snapshotURL(_ path: String) -> URL {
        var h: UInt64 = 0xcbf29ce484222325
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return snapshots.appendingPathComponent(String(h, radix: 16, uppercase: false))
    }

    private func writeSnapshot(_ url: URL) {
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        // Cap it. A snapshot exists to show a diff, and a multi-megabyte file
        // is not one a person reviews line by line.
        guard data.count <= 2_000_000 else { return }
        try? data.write(to: snapshotURL(url.path), options: .atomic)
    }

    /// The content this file had the last time it was opened here.
    func snapshot(for url: URL) -> String? {
        guard let d = try? Data(contentsOf: snapshotURL(url.path)) else { return nil }
        return (try? ByteCodec.decode(d))?.text as String?
    }

    /// True when the file on disk differs from the snapshot.
    func hasChangedSinceOpened(_ url: URL) -> Bool { delta(for: url) != nil }

    /// Which document the window currently holds. Separate from markSeen
    /// because the identity guard belongs HERE and not there: it exists to stop
    /// a cold start probing the whole rail twice, once from
    /// makeWindowControllers and once from the rail's first reload. Putting it
    /// on markSeen instead — which I did, and the tests caught — permanently
    /// refuses to re-ratify a file you open a second time.
    ///
    /// - Returns: true when the open document actually changed.
    @discardableResult
    func setOpenDocument(_ url: URL?) -> Bool {
        guard url != openURL else { return false }
        openURL = url
        markSeen(url)
        return true
    }

    private var openURL: URL?

    private func measure(_ url: URL) -> Entry? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let m = mtime(url.path) else { return nil }

        var lines = 0
        for b in data where b == 0x0A { lines += 1 }
        if let last = data.last, last != 0x0A { lines += 1 }

        let digest = SHA256.hash(data: data)
        var h: UInt64 = 0
        for (i, byte) in digest.enumerated() where i < 8 { h = (h << 8) | UInt64(byte) }

        return Entry(hash: h, lines: lines, mtime: m)
    }

    private var flush: DispatchWorkItem?
    private func scheduleFlush() {
        flush?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.write() }
        flush = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    private func write() {
        lock.lock()
        let snapshot = entries
        let isDirty = dirty
        dirty = false
        lock.unlock()
        guard isDirty, let d = try? JSONEncoder().encode(snapshot) else { return }
        try? d.write(to: url, options: .atomic)
    }

    /// Drop state for files that no longer exist, so the store cannot grow
    /// without bound as projects are renamed and retired.
    ///
    /// This covers BOTH halves. The snapshot directory was previously
    /// unbounded: a renamed project leaves its content snapshots behind
    /// forever, and nothing ever removed them.
    func prune() {
        let fm = FileManager.default
        lock.lock()
        let keys = Array(entries.keys)
        lock.unlock()

        let live = keys.filter { fm.fileExists(atPath: $0) }
        let liveSet = Set(live)

        if liveSet.count != keys.count {
            lock.lock()
            entries = entries.filter { liveSet.contains($0.key) }
            dirty = true
            lock.unlock()
            scheduleFlush()
        }

        // A snapshot with no surviving entry can never be shown again.
        let keep = Set(live.map { snapshotURL($0).lastPathComponent })
        if let files = try? fm.contentsOfDirectory(atPath: snapshots.path) {
            for f in files where !keep.contains(f) {
                try? fm.removeItem(at: snapshots.appendingPathComponent(f))
            }
        }
    }
}
