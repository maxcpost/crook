import Foundation
import CoreServices
import CryptoKit

// Crook's remote agent.
//
// Runs ON the machine that owns the files. Speaks newline-delimited JSON over
// stdin and stdout and nothing else, which is exactly the shape
// `ssh host crook-agent` hands you: no ports, no daemon, no launchd job, no
// TLS to configure. The transport is whatever carries the SSH session; over a
// tailnet that is WireGuard, and this program neither knows nor cares.
//
// It exists rather than a mounted disk because every question Crook asks about
// a path must be answered by the machine that owns it. `exists` decides whether
// a link in a skill file is dead. `home` decides what Claude Code even reads.
// And change notification cannot cross a mount at all — the client kernel never
// observes another host's writes, so FSEvents has to run here.

let AGENT_VERSION = 2

let out = FileHandle.standardOutput
let outLock = NSLock()

func emit(_ obj: [String: Any]) {
    guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
    d.append(0x0A)
    outLock.lock(); out.write(d); outLock.unlock()
}

// MARK: - what counts

let excludedDirs: Set<String> = [
    "node_modules", ".git", ".build", "dist", "build", "vendor",
    "shell-snapshots", "statsig", "todos", "ide", "plugins",
]

/// Mirrors Workspace.isClaudeFile. Deliberately a shade more permissive: the
/// client filters again, and it is cheaper to send a file that gets dropped
/// than to be missing one the client wanted.
func isClaudeFile(_ name: String) -> Bool {
    if name == "settings.json" || name == "settings.local.json" { return true }
    if name == ".mcp.json" { return true }
    let lower = name.lowercased()
    return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
}

let visibleDotfiles: Set<String> = [".claude", ".mcp.json"]

/// Paths the agent will serve. Not a privilege boundary — this runs as the
/// connecting user and could read anything that user can — but it bounds the
/// blast radius of a bug on the client side.
var allowedRoots: [String] = []

func permitted(_ path: String) -> Bool {
    if allowedRoots.isEmpty { return true }
    let p = (path as NSString).standardizingPath
    return allowedRoots.contains { p == $0 || p.hasPrefix($0 + "/") }
}

// MARK: - tree

func countLines(_ url: URL, size: Int) -> Int? {
    // Counting is cheap HERE and expensive across a link: without it every
    // changed file would need a round trip before its "+7" could be drawn.
    guard size <= 4_000_000, let d = FileManager.default.contents(atPath: url.path) else { return nil }
    if d.isEmpty { return 0 }
    var n = d.reduce(into: 0) { acc, b in if b == 0x0A { acc += 1 } }
    if d.last != 0x0A { n += 1 }
    return n
}

func walk(_ root: String) -> [[Any]] {
    var rows: [[Any]] = []
    let fm = FileManager.default
    var stack = [URL(fileURLWithPath: root)]
    var depth: [String: Int] = [root: 0]

    while let dir = stack.popLast() {
        let d = depth[dir.path] ?? 0
        guard d < 8 else { continue }
        guard let kids = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: []) else { continue }
        for k in kids {
            let leaf = k.lastPathComponent
            if leaf.hasPrefix("."), !visibleDotfiles.contains(leaf) { continue }
            let v = try? k.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            let isDir = v?.isDirectory ?? false
            let mtime = (v?.contentModificationDate ?? .distantPast).timeIntervalSince1970
            if isDir {
                if excludedDirs.contains(leaf) { continue }
                rows.append([k.path, true, mtime, 0, NSNull()])
                depth[k.path] = d + 1
                stack.append(k)
            } else if isClaudeFile(leaf) {
                let size = v?.fileSize ?? 0
                rows.append([k.path, false, mtime, size, countLines(k, size: size) ?? NSNull()])
            }
        }
    }
    return rows
}

// MARK: - watching

// FSEvents runs here, on the machine that owns the disk, because that is the
// only place it can run. This is the capability a mounted filesystem can never
// give back: SMB, NFS and SSHFS all leave the client kernel blind to another
// host's writes.
var stream: FSEventStreamRef?

func startWatch(_ roots: [String]) {
    if let s = stream {
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil
    }
    guard !roots.isEmpty else { return }
    var ctx = FSEventStreamContext()
    let cb: FSEventStreamCallback = { _, _, count, paths, _, _ in
        // Only valid because the stream is created with UseCFTypes. Without that
        // flag this argument is a plain char**, and reading it as an NSArray
        // takes the process down — which is exactly what it did the first time.
        guard let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
        let changed = Array(arr.prefix(count))
        if !changed.isEmpty { emit(["ev": "changed", "paths": changed]) }
    }
    guard let s = FSEventStreamCreate(
        nil, cb, &ctx, roots as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.2,   // the same settle window the local watcher uses
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                 | kFSEventStreamCreateFlagNoDefer
                                 | kFSEventStreamCreateFlagUseCFTypes)
    ) else { emit(["ev": "error", "message": "could not create event stream"]); return }
    stream = s
    FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
    FSEventStreamStart(s)
    emit(["ev": "watching", "roots": roots])
}

// MARK: - handshake

func selfHash() -> String {
    guard let d = FileManager.default.contents(atPath: CommandLine.arguments[0]) else { return "" }
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

#if arch(arm64)
let arch = "arm64"
#else
let arch = "x86_64"
#endif

if CommandLine.arguments.contains("--version") {
    // Used by the client to decide whether the installed copy is current
    // before committing to a session.
    print("crook-agent \(AGENT_VERSION) \(arch)")
    exit(0)
}

emit(["ev": "hello", "version": AGENT_VERSION, "home": NSHomeDirectory(),
      "host": ProcessInfo.processInfo.hostName, "arch": arch, "sha256": selfHash()])

// MARK: - command loop

while let line = readLine(strippingNewline: true) {
    guard let d = line.data(using: .utf8),
          let cmd = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let op = cmd["op"] as? String else { continue }
    let id = cmd["id"] as? Int ?? 0

    switch op {
    case "roots":
        allowedRoots = (cmd["paths"] as? [String] ?? []).map { ($0 as NSString).standardizingPath }
        emit(["id": id, "ok": true, "roots": allowedRoots])

    case "tree":
        var rows: [[Any]] = []
        for r in (cmd["roots"] as? [String] ?? []) where permitted(r) {
            rows.append(contentsOf: walk(r))
        }
        emit(["id": id, "ok": true, "rows": rows])

    case "stat":
        // Arbitrary paths, outside any snapshot: project candidates decoded from
        // slugs, and the targets of absolute links found inside files.
        var res: [[Any]] = []
        for p in (cmd["paths"] as? [String] ?? []) {
            var st = stat()
            if lstat(p, &st) == 0 {
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                res.append([p, true, isDir,
                            Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                            Int(st.st_size)])
            } else {
                res.append([p, false, false, 0, 0])
            }
        }
        emit(["id": id, "ok": true, "stats": res])

    case "read":
        guard let p = cmd["path"] as? String, permitted(p),
              let data = FileManager.default.contents(atPath: p) else {
            emit(["id": id, "ok": false, "error": "unreadable"]); break
        }
        emit(["id": id, "ok": true, "b64": data.base64EncodedString()])

    case "write":
        guard let p = cmd["path"] as? String, permitted(p),
              let b64 = cmd["b64"] as? String, let data = Data(base64Encoded: b64) else {
            emit(["id": id, "ok": false, "error": "bad payload"]); break
        }
        // Temp-and-rename, executed on this side, so a link that drops mid-write
        // cannot leave a truncated file where a whole one used to be. Through a
        // symlink to the file it names: CLAUDE.md is often a link to AGENTS.md,
        // and the swap cannot replace a link.
        // The roots permit the path as the tree shows it. Where a link takes it
        // is not checked against them: a project reached through a linked
        // folder (Dropbox and Google Drive set theirs up that way) resolves
        // outside its own root, and must still save.
        let fm = FileManager.default
        let target = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: target, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            emit(["id": id, "ok": false, "error": "is a folder"]); break
        }
        let tmp = target + ".crook-tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            if exists {
                let before = try? fm.attributesOfItem(atPath: target)
                _ = try fm.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: tmp))
                if let group = before?[.groupOwnerAccountID] {
                    try? fm.setAttributes([.groupOwnerAccountID: group], ofItemAtPath: target)
                }
                if let mode = before?[.posixPermissions] {
                    try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target)
                }
            } else {
                try fm.moveItem(atPath: tmp, toPath: target)
            }
            emit(["id": id, "ok": true, "bytes": data.count])
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            emit(["id": id, "ok": false, "error": "\(error)"])
        }

    case "symlink":
        let p = cmd["path"] as? String ?? ""
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: p)
        emit(["id": id, "ok": true, "dest": dest ?? NSNull()])

    case "watch":
        startWatch((cmd["roots"] as? [String] ?? []).filter(permitted))
        emit(["id": id, "ok": true])

    case "ping":
        emit(["id": id, "ok": true])

    case "bye":
        emit(["id": id, "ok": true])
        exit(0)

    default:
        emit(["id": id, "ok": false, "error": "unknown op \(op)"])
    }
}
