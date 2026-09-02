import Foundation

/// Watches the open document for writes by anything that is not Crook.
///
/// This app's defining condition is that another process rewrites the open file
/// constantly. Without a watcher the editor shows a stale buffer and says
/// nothing about it, which is the one failure a tool for agent-written files
/// cannot have.
///
/// A DispatchSource vnode watch rather than FSEvents: the target is one file,
/// not a tree, and vnode delivers per-file events with no directory scan. The
/// cost is that an atomic save — write to temp, rename over — deletes the inode
/// we are watching, so `.delete` and `.rename` mean "re-arm", not "gone". Every
/// editor and most agents save that way, so this is the common path, not an
/// edge case.
final class FileWatcher {

    enum Change {
        case written        // the bytes on disk differ from what we loaded
        case vanished       // the file is gone and has not come back
    }

    private var source: DispatchSourceFileSystemObject?
    private var fd: CInt = -1
    private var url: URL?
    private var rearm: DispatchWorkItem?
    private var settle: DispatchWorkItem?
    /// A write is not one event. Measured: a twelve-line streamed write fired
    /// twelve vnode events, and without a settle window each one reloads the
    /// buffer — so the reader watches the file grow line by line, seeing
    /// partial content that was never a state the author intended.
    private let settleWindow: TimeInterval = 0.20
    private let onChange: (Change) -> Void

    init(onChange: @escaping (Change) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ url: URL?) {
        stop()
        guard let url else { return }
        self.url = url
        arm()
    }

    func stop() {
        rearm?.cancel(); rearm = nil
        settle?.cancel(); settle = nil
        source?.cancel(); source = nil
        // fd is closed by the source's cancel handler.
        url = nil
    }

    private func arm() {
        guard let url else { return }
        let f = open(url.path, O_EVTONLY)
        guard f >= 0 else {
            // Not there yet. An atomic rename lands within a few ms; anything
            // longer and the file is genuinely gone.
            scheduleRearm(deadline: 0.15, reportVanishedAfter: true)
            return
        }
        fd = f
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: f,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke],
            queue: .main)
        s.setEventHandler { [weak self] in
            guard let self, let s = self.source else { return }
            let flags = s.data
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // Atomic save: the inode we hold is now detached. Re-open the
                // path and report a write, not a deletion.
                self.scheduleRearm(deadline: 0.05, reportVanishedAfter: false)
            }
            self.coalesce()
        }
        s.setCancelHandler { [f] in close(f) }
        source = s
        s.resume()
    }

    /// Report once, after the writes stop.
    private func coalesce() {
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onChange(.written) }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + settleWindow, execute: w)
    }

    private func scheduleRearm(deadline: TimeInterval, reportVanishedAfter: Bool) {
        source?.cancel(); source = nil
        rearm?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let url = self.url else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                self.arm()
            } else if reportVanishedAfter {
                self.onChange(.vanished)
            } else {
                // One more grace period before calling it gone.
                self.scheduleRearm(deadline: 0.3, reportVanishedAfter: true)
            }
        }
        rearm = w
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline, execute: w)
    }
}
