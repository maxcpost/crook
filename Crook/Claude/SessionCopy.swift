import Foundation

/// What the banner across the editor shows. A value, so what a state looks
/// like can be tested without drawing it.
struct BannerContent: Equatable {
    enum Tone: Equatable { case live, attention, warning, ended }
    enum Action: Equatable { case showTerminal, endSession, review, undo, redo, done }

    struct Button: Equatable {
        let action: Action
        let title: String
        var help: String? = nil
        var enabled = true
    }

    var tone: Tone
    var title: String
    var note: String?
    var buttons: [Button]
    /// Other files that changed during the session, relative to its folder.
    var alsoChanged: [String]
}

/// Every sentence Edit with Claude shows, in one place — so the copy can be
/// read as the design it is, and tested like one.
enum SessionCopy {

    // MARK: - title bar

    static let button = "Edit with Claude"
    static let buttonOpening = "Opening…"
    static let buttonRunning = "Editing with Claude"
    static let buttonHelp = "Describe a change and Claude Code makes it (⇧⌘E)"
    static let buttonRunningHelp = "Show the Claude Code session in Terminal (⇧⌘E)"
    static let vanishedHelp = "This file is no longer on disk."

    // MARK: - popover

    static let placeholder = "Describe the change, or leave this empty to talk it through"
    static let openButton = "Open Claude Code"
    static let tip = "Tip: select part of the file first to point Claude at it."
    /// Named, because the trust question's default answer is No (check S4).
    static let firstTime = "The first time, Claude Code may ask you to log in. In a folder it hasn't seen before, it asks whether you trust it: choose “Yes, I trust this folder”."

    static func selectionNote(_ r: ClosedRange<Int>) -> String {
        r.lowerBound == r.upperBound ? "Line \(r.lowerBound) selected" : "Lines \(r.lowerBound)–\(r.upperBound) selected"
    }

    static func footer(machine: String?) -> String {
        if let machine {
            return "Opens Claude Code on \(machine), in Terminal beside this window. Each change appears here as Claude saves it."
        }
        return "Opens Claude Code in Terminal, beside this window. Each change appears here as Claude saves it."
    }

    // MARK: - banner

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    struct BannerFacts: Equatable {
        var state: ClaudeSession.State
        var added: Int
        var removed: Int
        var fileVanished: Bool
        var machineName: String?
        var nudging: Bool
        /// nil: not offered at all.
        var undo: Availability?
        var redo: Availability?
        var alsoChanged: [String]
    }

    /// U+2212 MINUS SIGN, as the rail uses, so the figures line up.
    static func tally(_ added: Int, _ removed: Int) -> String { "+\(added) \u{2212}\(removed)" }

    static func banner(_ f: BannerFacts) -> BannerContent? {
        let showTerminal = BannerContent.Button(action: .showTerminal, title: "Show Terminal")
        let endSession = BannerContent.Button(action: .endSession, title: "End Session")
        let review = BannerContent.Button(action: .review, title: "Review Changes")
        let done = BannerContent.Button(action: .done, title: "Done")
        let changed = f.added + f.removed > 0

        switch f.state {
        case .opening:
            return BannerContent(tone: .live, title: "Opening Claude Code in Terminal…", note: nil,
                                 buttons: [], alsoChanged: [])
        case .stopping:
            return BannerContent(tone: .live, title: "Ending the session…", note: nil, buttons: [], alsoChanged: [])
        case .running:
            if f.fileVanished {
                return BannerContent(tone: .warning, title: "Claude moved or deleted this file",
                                     note: "The sidebar shows what's there now",
                                     buttons: [showTerminal, endSession], alsoChanged: [])
            }
            let note: String
            if f.nudging { note = "To edit it yourself, finish in Terminal or click End Session" }
            else if changed { note = "\(tally(f.added, f.removed)) so far · read-only until you finish" }
            else { note = "Read-only here until you finish" }
            return BannerContent(tone: f.nudging ? .attention : .live, title: "Editing with Claude in Terminal",
                                 note: note, buttons: [showTerminal, endSession], alsoChanged: [])
        case .ended(let outcome):
            let title: String, tone: BannerContent.Tone, since: String
            switch outcome {
            case .finished:
                title = "Finished editing with Claude"; tone = .ended; since = "in this file"
            case .connectionLost:
                title = "The connection to \(f.machineName ?? "that Mac") closed, which ended the session"
                tone = .warning; since = "saved before it closed"
            case .stoppedUnexpectedly:
                title = "Claude Code stopped unexpectedly"; tone = .warning; since = "saved before it stopped"
            default:
                return nil   // an alert says these; there is nothing to review
            }
            var buttons: [BannerContent.Button] = []
            let note: String
            if f.fileVanished {
                note = "This file was moved or deleted"
                if changed { buttons.append(review) }
            } else if changed {
                note = "\(tally(f.added, f.removed)) \(since)"
                buttons.append(review)
                if let undo = f.undo { buttons.append(button(.undo, "Undo Changes", undo)) }
            } else {
                note = "This file wasn't changed"
            }
            buttons.append(done)
            return BannerContent(tone: tone, title: title, note: note, buttons: buttons, alsoChanged: f.alsoChanged)
        case .restored:
            var buttons: [BannerContent.Button] = []
            if let redo = f.redo { buttons.append(button(.redo, "Redo Changes", redo)) }
            buttons.append(done)
            return BannerContent(tone: .ended, title: "Restored the version from before Claude's changes",
                                 note: nil, buttons: buttons, alsoChanged: [])
        }
    }

    private static func button(_ action: BannerContent.Action, _ title: String,
                               _ availability: Availability) -> BannerContent.Button {
        switch availability {
        case .available: return .init(action: action, title: title)
        case .unavailable(let why): return .init(action: action, title: title, help: why, enabled: false)
        }
    }

    /// Whether Undo or Redo can run right now, why not, or nil when it should
    /// not be offered at all.
    static func swapAvailability(verb: String, fileVanished: Bool, connected: Bool,
                                 machine: String?, diskMatches: Bool) -> Availability? {
        if fileVanished { return nil }
        if !connected { return .unavailable("Reconnect to \(machine ?? "that Mac") to \(verb).") }
        return diskMatches ? .available : .unavailable("This file has changed since the session ended.")
    }

    // MARK: - VoiceOver

    static let startedAnnouncement = "Claude Code is open in Terminal."

    static func changedAnnouncement(_ lines: [Int]) -> String {
        guard let first = lines.first, let last = lines.last else { return "" }
        return first == last ? "Claude changed line \(first)." : "Claude changed lines \(first) to \(last)."
    }

    static func endedAnnouncement(added: Int, removed: Int) -> String {
        added + removed == 0
            ? "Claude's session has ended. This file wasn't changed."
            : "Claude's session has ended. \(added) lines added, \(removed) removed."
    }

    // MARK: - alerts

    struct Alert: Equatable {
        let title: String
        let message: String
        let buttons: [String]
    }

    static func missing(machine: String?) -> Alert {
        guard let machine else {
            return Alert(title: "Claude Code isn't installed on this Mac.",
                         message: "Edit with Claude opens Claude Code, which isn't installed here yet. Install it, then try again.",
                         buttons: ["How to Install", "OK"])
        }
        return Alert(title: "Claude Code isn't installed on \(machine).",
                     message: "Claude works on the Mac where the file lives. Install Claude Code on \(machine), then try again.",
                     buttons: ["How to Install", "OK"])
    }

    static func tooOld(machine: String?, installed: String) -> Alert {
        Alert(title: "Claude Code on \(machine ?? "this Mac") needs an update.",
              message: "Edit with Claude needs version \(ClaudePreflight.minimumVersion) or later. \(machine ?? "This Mac") has \(installed).",
              buttons: ["Update in Terminal", "Cancel"])
    }

    static func notConnected(machine: String) -> Alert {
        Alert(title: "Crook isn't connected to \(machine).",
              message: "Reconnect to open Claude Code there. Your file hasn't changed.",
              buttons: ["Reconnect", "Cancel"])
    }

    static func conflict(fileName: String) -> Alert {
        Alert(title: "\(fileName) changed on disk while you were editing.",
              message: "Choose the version Claude should work on.",
              buttons: ["Use My Version", "Use Disk Version", "Cancel"])
    }

    static func vanished(fileName: String) -> Alert {
        Alert(title: "\(fileName) is no longer on disk.", message: "It may have been moved or deleted.", buttons: ["OK"])
    }

    static func folderAccess(protectedFolder: String?) -> Alert {
        let message = protectedFolder.map {
            "macOS hasn't given Terminal access to your \($0) folder. Turn it on in System Settings, then try again."
        } ?? "macOS didn't let Terminal open that folder. Check Terminal under Files and Folders in System Settings, then try again."
        return Alert(title: "Terminal can't open the folder this file is in.", message: message,
                     buttons: ["Open Privacy Settings", "OK"])
    }

    static let didNotStart = Alert(title: "Claude Code didn't start.",
                                   message: "If a Terminal window opened, it shows what went wrong.",
                                   buttons: ["OK"])

    static let closedWithoutChanges = Alert(
        title: "Claude Code closed without making changes.",
        message: "If it asked whether to trust this folder, try again and choose “Yes, I trust this folder”. Otherwise, Terminal shows what went wrong.",
        buttons: ["Try Again", "OK"])

    static func folderMissing(machine: String?) -> Alert {
        Alert(title: machine.map { "The folder for this file is missing on \($0)." } ?? "The folder for this file is missing.",
              message: "Claude Code needs to start in that folder. It may have been moved or renamed.",
              buttons: ["OK"])
    }

    static func couldNotConnect(machine: String?) -> Alert {
        Alert(title: "Couldn't reach \(machine ?? "that Mac") from Terminal.",
              message: "ssh reported a problem, and Terminal shows what it said. Check that Crook is still connected, then try again.",
              buttons: ["OK"])
    }

    static func couldNotOpen(_ reason: String) -> Alert {
        Alert(title: "Couldn't open Claude Code.", message: reason, buttons: ["OK"])
    }

    /// The alert that stands in for a banner, for endings with nothing to review.
    static func alert(for outcome: SessionRunner.Outcome, machine: String?, protectedFolder: String?) -> Alert? {
        switch outcome {
        case .claudeMissing: return missing(machine: machine)
        case .folderMissing: return folderMissing(machine: machine)
        case .folderAccess: return folderAccess(protectedFolder: protectedFolder)
        case .couldNotConnect: return couldNotConnect(machine: machine)
        case .closedWithoutChanges: return closedWithoutChanges
        case .didNotStart: return didNotStart
        case .finished, .connectionLost, .stoppedUnexpectedly: return nil
        }
    }

    static let installURL = URL(string: "https://code.claude.com/docs/en/setup")!
    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
}
