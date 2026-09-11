import Foundation
import Darwin

/// One Edit with Claude session: the file, the machine, the folder its runner
/// reads, and what has happened so far.
///
/// The session itself belongs to Terminal. This is Crook's record of it —
/// enough, in session.json, to pick it up again after Crook quits.
final class ClaudeSession {

    enum State: Equatable {
        case opening
        case running
        case stopping
        case ended(SessionRunner.Outcome)
        /// After Undo. Redo goes back to `ended`.
        case restored(SessionRunner.Outcome)
    }

    struct Record: Codable, Equatable {
        var id: UUID
        var filePath: String
        var providerID: String
        var machineName: String?
        var workingDirectory: String
        var startedAt: Date
        var runnerPID: Int32?
        var crookFrameBefore: CGRect?
        var crookFrameSet: CGRect?
        var endRequested = false
        var outcome: SessionRunner.Outcome?
        var endedAt: Date?
        var restored = false
        /// Fingerprints of the other files near this one as the session began.
        var fingerprintsAtStart: [String: String] = [:]
        /// Absolute paths of the files near this one that changed during it.
        var alsoChanged: [String] = []
    }

    let folder: URL
    var record: Record
    var state: State
    /// The file went away while the session ran, or by the time it ended.
    var fileVanished = false
    /// Placement and first-run bookkeeping have been done for this session.
    var handledStart = false
    /// Found already over when Crook launched: its failures are old news.
    var endedWhileAway = false
    /// Picked up after Crook restarted. Crook centres its window on launch, so
    /// only the size it set can be compared, not the position.
    var reattached = false

    init(folder: URL, record: Record, state: State) {
        self.folder = folder
        self.record = record
        self.state = state
    }

    var id: UUID { record.id }
    var isRemote: Bool { record.providerID != Providers.local.id }

    var isLive: Bool {
        switch state {
        case .opening, .running, .stopping: return true
        case .ended, .restored: return false
        }
    }

    var outcome: SessionRunner.Outcome? {
        switch state {
        case .ended(let o), .restored(let o): return o
        default: return nil
        }
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// The file's exact bytes when the session began: what Undo puts back.
    var baseline: Data? { try? Data(contentsOf: file("baseline")) }
    /// The file's exact bytes when it ended: what Redo puts back.
    var finalBytes: Data? { try? Data(contentsOf: file("final")) }
}

/// Every session Crook knows about, and the processes behind them.
///
/// A start is noticed when the runner writes its PID; an end when that process
/// exits, through a kqueue process source. That works for any process this
/// user owns, not only Crook's own children — which is what lets a session
/// outlive Crook and be picked up again.
final class SessionRegistry {

    static let shared = SessionRegistry()

    /// Disposable state, outside every project, in a path with no spaces.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crook/sessions", isDirectory: true)
    }

    let root: URL
    private(set) var sessions: [ClaudeSession] = []
    /// On the main queue, after any session's state changes.
    var onChange: ((ClaudeSession) -> Void)?
    /// Whether a session's file differs from its baseline; asked as it ends.
    var fileChanged: ((ClaudeSession) -> Bool)?

    private var startTimers: [UUID: Timer] = [:]
    private var exitSources: [UUID: DispatchSourceProcess] = [:]

    init(root: URL = SessionRegistry.defaultRoot) {
        self.root = root
    }

    // MARK: - beginning

    func begin(id: UUID = UUID(), filePath: String, providerID: String, machineName: String?,
               workingDirectory: String, baseline: Data) throws -> ClaudeSession {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try baseline.write(to: folder.appendingPathComponent("baseline"), options: .atomic)
        let record = ClaudeSession.Record(id: id, filePath: filePath, providerID: providerID,
                                          machineName: machineName, workingDirectory: workingDirectory,
                                          startedAt: Date())
        let s = ClaudeSession(folder: folder, record: record, state: .opening)
        sessions.append(s)
        save(s)
        return s
    }

    func save(_ s: ClaudeSession) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(s.record) else { return }
        try? data.write(to: s.file("session.json"), options: .atomic)
    }

    // MARK: - finding

    /// The session to show for a file: a live one first, else the most recent
    /// one still waiting for Done.
    func session(for path: String, providerID: String) -> ClaudeSession? {
        let mine = sessions.filter { $0.record.filePath == path && $0.record.providerID == providerID }
        return mine.last(where: { $0.isLive }) ?? mine.last
    }

    func liveSession(for path: String, providerID: String) -> ClaudeSession? {
        sessions.last { $0.isLive && $0.record.filePath == path && $0.record.providerID == providerID }
    }

    // MARK: - watching

    /// Wait for the runner to report in, then for it to exit.
    func watch(_ s: ClaudeSession, startTimeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(startTimeout)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if let pid = Self.readPID(s.file("runner.pid")) {
                t.invalidate()
                self.startTimers[s.id] = nil
                self.runnerStarted(s, pid: pid)
            } else if !s.isLive || Date() > deadline {
                t.invalidate()
                self.startTimers[s.id] = nil
                guard s.isLive else { return }
                FileManager.default.createFile(atPath: s.file("abandoned").path, contents: nil)
                self.finish(s, .didNotStart)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        startTimers[s.id] = timer
    }

    private func runnerStarted(_ s: ClaudeSession, pid: Int32) {
        s.record.runnerPID = pid
        if s.state == .opening { s.state = .running }
        save(s)
        onChange?(s)
        attachExitSource(s, pid: pid)
    }

    private func attachExitSource(_ s: ClaudeSession, pid: Int32) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self, weak source] in
            source?.cancel()
            self?.exitSources[s.id] = nil
            self?.runnerExited(s)
        }
        exitSources[s.id] = source
        source.resume()
        // A runner that finished before the source existed never fires it.
        if kill(pid, 0) != 0 && errno == ESRCH {
            source.cancel()
            exitSources[s.id] = nil
            runnerExited(s)
        }
    }

    private func runnerExited(_ s: ClaudeSession) {
        guard s.isLive else { return }
        let report = (try? String(contentsOf: s.file("exit"), encoding: .utf8)).flatMap(SessionRunner.parseExit)
        let changed = fileChanged?(s) ?? false
        finish(s, SessionRunner.outcome(exit: report, endRequested: s.record.endRequested,
                                        isRemote: s.isRemote, fileChanged: changed))
    }

    private func finish(_ s: ClaudeSession, _ outcome: SessionRunner.Outcome) {
        s.state = .ended(outcome)
        s.record.outcome = outcome
        s.record.endedAt = Date()
        save(s)
        onChange?(s)
    }

    // MARK: - ending

    /// End Session: SIGTERM to Claude Code — or to ssh, whose exit hangs up
    /// Claude Code on the far side — then SIGKILL if it is still there three
    /// seconds later. Claude Code sitting at its trust question ignores
    /// SIGTERM (check S5), so the second step is not hypothetical.
    func requestEnd(_ s: ClaudeSession) {
        guard s.state == .running else { return }
        s.record.endRequested = true
        FileManager.default.createFile(atPath: s.file("end-requested").path, contents: nil)
        s.state = .stopping
        save(s)
        onChange?(s)
        guard let runner = s.record.runnerPID else { return }
        // Claude Code (or ssh), if the runner has started it; the runner itself
        // otherwise. Only ever a process that is still demonstrably this
        // session's: the runner's own child, or the runner.
        let child = Self.readPID(s.file("child.pid")).flatMap { Self.parentPID(of: $0) == runner ? $0 : nil }
        let target = child ?? runner
        guard Self.stillOurs(target, runner: runner, folder: s.folder) else { return }
        kill(target, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard s.state == .stopping, Self.stillOurs(target, runner: runner, folder: s.folder) else { return }
            kill(target, SIGKILL)
        }
    }

    private static func stillOurs(_ pid: Int32, runner: Int32, folder: URL) -> Bool {
        pid == runner ? isRunner(pid: runner, of: folder) : parentPID(of: pid) == runner
    }

    /// Done: forget the session, folder and all.
    ///
    /// `deletingFolderAfter` keeps the folder a little longer. A runner that
    /// just exited is still closing its Terminal window, and the script that
    /// does it is read from this folder.
    func discard(_ s: ClaudeSession, deletingFolderAfter delay: TimeInterval = 0) {
        startTimers.removeValue(forKey: s.id)?.invalidate()
        exitSources.removeValue(forKey: s.id)?.cancel()
        sessions.removeAll { $0 === s }
        let folder = s.folder
        guard delay > 0 else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - after a restart

    /// Pick up the sessions from before Crook last quit.
    ///
    /// A runner still going is recognised by its arguments, which name this
    /// session's launch.command; a reused process ID cannot pass that. One that
    /// finished meanwhile is ended now, as though Crook had watched it. Anything
    /// a week old, or that never started, is cleared away.
    func reattach(now: Date = Date()) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let name = folder.lastPathComponent
            guard !sessions.contains(where: { $0.folder.lastPathComponent == name }) else { continue }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let record = try? JSONDecoder().decode(ClaudeSession.Record.self, from: data) else {
                try? fm.removeItem(at: folder)
                continue
            }
            let s = ClaudeSession(folder: folder, record: record, state: .opening)
            s.handledStart = true
            s.reattached = true
            if let outcome = record.outcome {
                if let ended = record.endedAt, now.timeIntervalSince(ended) > 7 * 86_400 {
                    try? fm.removeItem(at: folder)
                    continue
                }
                s.state = record.restored ? .restored(outcome) : .ended(outcome)
                s.endedWhileAway = true
                sessions.append(s)
                continue
            }
            guard let pid = record.runnerPID ?? Self.readPID(folder.appendingPathComponent("runner.pid")) else {
                // Never started: nothing happened that anyone needs telling about.
                try? fm.removeItem(at: folder)
                continue
            }
            s.record.runnerPID = pid
            s.state = .running
            sessions.append(s)
            if Self.isRunner(pid: pid, of: folder) {
                attachExitSource(s, pid: pid)
            } else {
                s.endedWhileAway = true
                runnerExited(s)
            }
        }
    }

    // MARK: - processes

    static func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A process's parent, from the kernel.
    static func parentPID(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Whether `pid` is alive and running this folder's launch.command.
    static func isRunner(pid: Int32, of folder: URL) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        let script = folder.appendingPathComponent("launch.command").path
        let resolved = folder.resolvingSymlinksInPath().appendingPathComponent("launch.command").path
        return arguments(of: pid)?.contains { $0 == script || $0 == resolved } ?? false
    }

    /// A process's arguments, from the kernel (KERN_PROCARGS2: argc, the
    /// executable path, padding, then the NUL-terminated arguments).
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
