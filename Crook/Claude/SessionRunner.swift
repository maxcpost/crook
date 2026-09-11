import Foundation

/// The scripts that run a session, and what their exit means.
///
/// Two rules shape all of it. The scripts are static — the same text for every
/// session — and read everything specific from files beside them. And no text
/// that came from a file name, a path, a machine or a person's request is ever
/// placed into shell source: it travels NUL-separated and reaches the program
/// as arguments. Quoting is where launchers like this break, and the way not to
/// get quoting wrong is not to do any.
enum SessionRunner {

    enum Outcome: String, Codable, Equatable {
        case finished
        case claudeMissing
        case folderMissing
        case folderAccess
        case couldNotConnect
        case connectionLost
        case closedWithoutChanges
        case stoppedUnexpectedly
        case didNotStart
    }

    struct Exit: Equatable {
        let status: Int32
        let seconds: Int
    }

    /// The runners' own failures, clear of anything Claude Code or ssh exits with.
    static let claudeMissingStatus: Int32 = 90
    static let folderMissingStatus: Int32 = 91
    static let folderAccessStatus: Int32 = 92

    /// `exit` holds "status seconds".
    static func parseExit(_ text: String) -> Exit? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let status = Int32(parts[0]), let seconds = Int(parts[1]) else { return nil }
        return Exit(status: status, seconds: seconds)
    }

    /// What the person is told, from how the session ended.
    ///
    /// `exit` is nil when the runner wrote none: closing the Terminal window
    /// takes the runner with it. That is someone ending their own session, not
    /// a failure.
    static func outcome(exit: Exit?, endRequested: Bool, isRemote: Bool, fileChanged: Bool) -> Outcome {
        if endRequested { return .finished }
        guard let exit else { return .finished }
        switch exit.status {
        case 0, 130: return .finished
        case claudeMissingStatus: return .claudeMissing
        case folderMissingStatus: return .folderMissing
        case folderAccessStatus: return .folderAccess
        case 255 where isRemote: return exit.seconds < 10 ? .couldNotConnect : .connectionLost
        default:
            // Declining Claude Code's trust question exits 1 before anything
            // changed, and so does an error at startup. Both get the sentence
            // that suggests trying again; neither "stopped unexpectedly".
            return fileChanged ? .stoppedUnexpectedly : .closedWithoutChanges
        }
    }

    // MARK: - data, never code

    /// Fields separated by NUL, which cannot occur in a path or an argument.
    static func encodeFields(_ fields: [String]) -> Data {
        var d = Data()
        for f in fields {
            d.append(contentsOf: Array(f.replacingOccurrences(of: "\u{0}", with: "").utf8))
            d.append(0)
        }
        // Command substitution drops trailing newlines, which would clip the
        // last real field. A sentinel field takes that loss instead.
        d.append(UInt8(ascii: "."))
        return d
    }

    /// The command ssh runs on the other Mac.
    ///
    /// A fixed template holding two base64 tokens, whose alphabet has no quote,
    /// space or `$`. `/bin/sh -c '…'` makes it parse the same whether that
    /// Mac's login shell is zsh, bash, fish or tcsh. The decoded script is
    /// static; the payload is only ever data. `-f` keeps that Mac's .zshenv
    /// — its aliases and functions — out of a script that did not ask for them.
    static func remoteCommand(workingDirectory: String, arguments: [String]) -> String {
        let script = Data(remoteScript.utf8).base64EncodedString()
        let payload = encodeFields([workingDirectory] + arguments).base64EncodedString()
        return "/bin/sh -c 'exec /bin/zsh -fc \"$(printf %s \(script) | /usr/bin/base64 -D)\" crook \(payload)'"
    }

    // MARK: - scripts

    /// Finds `claude` the way the person's own shell would — a login,
    /// interactive one, since installers add to PATH in .zshrc — then where the
    /// installers put it. An alias or a function is not a path and falls
    /// through to the known locations.
    ///
    /// Sets CROOK_EXE, and CROOK_LOGIN_PATH to that shell's PATH. The answers
    /// are marked lines rather than "the last line", because a login script
    /// that prints a greeting would otherwise be read as the answer.
    static let resolveClaude = #"""
    crook_resolve_claude() {
      local out line c
      CROOK_EXE=""
      CROOK_LOGIN_PATH=""
      out=$(/usr/bin/perl -e 'alarm 8; exec @ARGV' "${SHELL:-/bin/zsh}" -lic 'printf "%s\n" "CROOK_PATH=$PATH"; command -v claude' </dev/null 2>/dev/null)
      for line in "${(@f)out}"; do
        line=${line//$'\r'/}
        case $line in
          CROOK_PATH=*) CROOK_LOGIN_PATH=${line#CROOK_PATH=} ;;
          /*) CROOK_EXE=$line ;;
        esac
      done
      [[ -x $CROOK_EXE ]] || CROOK_EXE=""
      if [[ -z $CROOK_EXE ]]; then
        for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.claude/local/claude"; do
          if [[ -x $c ]]; then CROOK_EXE=$c; break; fi
        done
      fi
    }

    """#

    /// Runs on the other Mac as `zsh -fc <this> crook <payload>`.
    static let remoteScript = "emulate -R zsh\n" + resolveClaude + #"""
    typeset -a f
    f=("${(@0)"$(print -rn -- "$1" | /usr/bin/base64 -D)"}")
    f[-1]=()
    dir=$f[1]
    shift f
    cd -- "$dir" 2>/dev/null || exit 91
    crook_resolve_claude
    [[ -n $CROOK_EXE ]] || exit 90
    # That Mac's login PATH, not sshd's bare one, so the MCP servers and hooks
    # Claude starts find npx, uvx and Homebrew the way they do in its terminal.
    [[ -n $CROOK_LOGIN_PATH ]] && export PATH=$CROOK_LOGIN_PATH
    exec "$CROOK_EXE" "${f[@]}"

    """#

    /// launch.command, which Terminal runs.
    static let localScript = #"""
    #!/bin/zsh -f
    # Crook: one Edit with Claude session.
    #
    # The same text for every session. Everything about this one is read from
    # the files beside it, and nothing read from them is run as shell code:
    # arguments arrive NUL-separated and are handed to the program as arguments.
    emulate -R zsh
    S=${0:A:h}
    cd -- "$S" || exit 1
    # Crook gave up waiting for this window (or the session was discarded):
    # starting Claude now would be a session nobody is watching.
    [[ -e abandoned ]] && exit 0
    print -r -- $$ > runner.pid.tmp && mv -f runner.pid.tmp runner.pid
    # Claude Code reads Ctrl-C as a key. Should one reach this script anyway,
    # carry on so the ending is still reported. A handler, not an ignore: an
    # ignored signal would stay ignored in the program run below.
    trap : INT

    # This window, so it can be placed beside Crook and closed at the end.
    W=""
    if [[ -f window.applescript ]]; then
      W=$(/usr/bin/osascript window.applescript find "$(tty)" 2>/dev/null)
      [[ $W == <-> ]] || W=""
      print -r -- "$W" > window
      if [[ -n $W && -s frame ]]; then
        /usr/bin/osascript window.applescript place "$W" ${(s: :)"$(<frame)"} >/dev/null 2>&1
        # A brand-new window is still Terminal's to position for a moment.
        # Say it again once it has settled.
        ( sleep 1; /usr/bin/osascript window.applescript place "$W" ${(s: :)"$(<frame)"} ) >/dev/null 2>&1 &!
      fi
    fi

    typeset -a cmd
    cmd=("${(@0)"$(<argv)"}")
    cmd[-1]=()
    started=$SECONDS
    st=0

    run_child() {
      print -n $'\e[2J\e[H'
      /bin/zsh -fc 'print -r -- $$ > "$1/child.pid"; shift; exec "$@"' crook "$S" "$@"
    }

    if [[ $(<mode) == local ]]; then
      if ! cd -- "$(<cwd)" 2>/dev/null; then
        st=91
      elif ! /bin/ls -- . >/dev/null 2>&1; then
        st=92
      else
        # The claude Crook checked is the one that runs. An older one earlier
        # on PATH would pass the version check and then refuse the arguments.
        exe=$cmd[1]
        [[ -x $exe ]] || exe=$(whence -p claude)
        if [[ -x $exe ]]; then
          run_child "$exe" "${(@)cmd[2,-1]}"
          st=$?
        else
          st=90
        fi
      fi
    else
      run_child "${(@)cmd}"
      st=$?
    fi

    cd -- "$S"
    print -r -- "$st $(( SECONDS - started ))" > exit.tmp && mv -f exit.tmp exit

    close_window() {
      [[ -n $W ]] || return 0
      /usr/bin/perl -MPOSIX -e 'setsid(); exec @ARGV' /usr/bin/osascript "$S/window.applescript" close-when-idle "$W" </dev/null >/dev/null 2>&1 &!
    }
    bring_crook_forward() {
      [[ -s bundle ]] && /usr/bin/open -b "$(<bundle)" >/dev/null 2>&1
    }

    if [[ -e end-requested ]]; then
      close_window
    elif (( st == 0 || st == 130 || (st >= 90 && st <= 92) )); then
      bring_crook_forward
      close_window
    elif [[ -s bundle ]]; then
      # A session Crook is watching: say where the explanation is. (Update in
      # Terminal has no bundle file, and its own output says what happened.)
      print
      print -r -- "Claude Code stopped. Crook has the details, and you can close this window."
    fi
    exit 0

    """#

    /// Crook's handle on the Terminal window its runner is in. Run from inside
    /// that window, so Terminal only ever talks about itself and macOS asks
    /// nobody for permission (check S2, S3). A window holding more than one tab
    /// belongs to the person, not the runner, and is left alone.
    static let windowScript = #"""
    on run argv
    	set verb to item 1 of argv
    	tell application "Terminal"
    		if verb is "find" then
    			set target to item 2 of argv
    			repeat with w in windows
    				if (count of tabs of w) is 1 then
    					set t to tab 1 of w
    					if ((tty of t) as text) is target and (busy of t) then return (id of w) as text
    				end if
    			end repeat
    			return ""
    		else if verb is "place" then
    			-- frame, not bounds: left, bottom, right, top in AppKit's global
    			-- coordinates, which land on the right display whatever screen
    			-- the window starts on.
    			set frame of window id ((item 2 of argv) as integer) to {(item 3 of argv) as integer, (item 4 of argv) as integer, (item 5 of argv) as integer, (item 6 of argv) as integer}
    		else if verb is "close-when-idle" then
    			set w to window id ((item 2 of argv) as integer)
    			repeat 100 times
    				if not (busy of tab 1 of w) then exit repeat
    				delay 0.1
    			end repeat
    			if (count of tabs of w) is 1 then close w
    		end if
    	end tell
    	return ""
    end run

    """#
}
