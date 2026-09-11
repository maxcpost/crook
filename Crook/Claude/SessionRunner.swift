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

    /// Finds `claude` the way the person's own shell would, and that shell's
    /// environment — a login, interactive one, since installers and API keys
    /// are set up in .zprofile and .zshrc — then where the installers put it.
    ///
    /// The shell runs in a session of its own with nothing to read from and
    /// its output in a file, so it cannot take keystrokes meant for Claude, and
    /// the time limit holds even when something it started keeps running. Only
    /// marked output counts: a login script that prints a greeting, or a path,
    /// is never taken for the answer. The probe is plain enough for zsh, bash
    /// and fish alike.
    ///
    /// Sets CROOK_EXE, and CROOK_LOGIN_ENV to that shell's `KEY=value` pairs.
    static let resolveClaude = #"""
    CROOK_PROBE='command -v claude | /usr/bin/sed "s/^/CROOK_EXE=/"; printf "\nCROOK_ENV_BEGIN\n"; /usr/bin/env -0; printf "\nCROOK_ENV_END\n"'
    typeset -ga CROOK_LOGIN_ENV
    crook_resolve_claude() {
      local tmp out head envpart line dir c
      CROOK_EXE=""
      CROOK_LOGIN_ENV=()
      tmp=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/crook.XXXXXX" 2>/dev/null) || tmp=""
      if [[ -n $tmp ]]; then
        /usr/bin/perl -MPOSIX -e '
          my $out = shift;
          my $pid = fork;
          exit 0 unless defined $pid;
          if (!$pid) {
            POSIX::setsid();
            open STDIN, "<", "/dev/null";
            open STDOUT, ">", $out;
            open STDERR, ">", "/dev/null";
            exec @ARGV or POSIX::_exit(127);
          }
          local $SIG{ALRM} = sub { kill "KILL", -$pid; exit 0 };
          alarm 8;
          waitpid $pid, 0;
        ' "$tmp" "${SHELL:-/bin/zsh}" -lic "$CROOK_PROBE" 2>/dev/null
        out=$(<$tmp)
        /bin/rm -f -- "$tmp"
      fi
      if [[ $out == *CROOK_ENV_BEGIN* ]]; then
        head=${out%%CROOK_ENV_BEGIN*}
        envpart=${out#*CROOK_ENV_BEGIN$'\n'}
        envpart=${envpart%$'\n'CROOK_ENV_END*}
        CROOK_LOGIN_ENV=("${(@0)envpart}")
      else
        head=$out
      fi
      for line in "${(@f)head}"; do
        line=${line//$'\r'/}
        [[ $line == CROOK_EXE=/* ]] && CROOK_EXE=${line#CROOK_EXE=}
      done
      [[ -f $CROOK_EXE && -x $CROOK_EXE ]] || CROOK_EXE=""
      # An alias or a function named claude answers with itself, not a path:
      # look along the shell's PATH instead, then where the installers put it.
      if [[ -z $CROOK_EXE ]]; then
        for dir in "${(@s.:.)$(crook_login_value PATH)}"; do
          if [[ $dir == /* && -f $dir/claude && -x $dir/claude ]]; then CROOK_EXE=$dir/claude; break; fi
        done
      fi
      if [[ -z $CROOK_EXE ]]; then
        for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.claude/local/claude"; do
          if [[ -f $c && -x $c ]]; then CROOK_EXE=$c; break; fi
        done
      fi
    }
    crook_login_value() {
      local kv
      for kv in "${CROOK_LOGIN_ENV[@]}"; do
        if [[ $kv == $1=* ]]; then print -r -- "${kv#$1=}"; return 0; fi
      done
      return 1
    }
    # That Mac's login environment, not sshd's bare one: the PATH its MCP
    # servers and hooks expect, and any API key, proxy or config folder set up
    # in its shell files. Only what describes this shell and terminal is left.
    crook_apply_login_env() {
      local kv k
      for kv in "${CROOK_LOGIN_ENV[@]}"; do
        [[ $kv == *=* ]] || continue
        k=${kv%%=*}
        [[ $k == [A-Za-z_]* && $k != *[^A-Za-z0-9_]* ]] || continue
        case $k in
          PWD|OLDPWD|SHLVL|_|TERM|TERM_*|COLUMNS|LINES|SSH_*|TMUX|TMUX_*|ZDOTDIR|UID|EUID|GID|EGID|PPID|USERNAME|SECONDS|RANDOM|LINENO|HISTCMD|CROOK_EXE|CROOK_DIR|CROOK_PROBE|CROOK_FIELDS|CROOK_LOGIN_ENV) continue ;;
        esac
        # A name zsh holds as read-only, or as an array (status, path, argv),
        # can't be exported as a string, and trying ends the script.
        [[ ${(Pt)k} == (*readonly*|array*|association*) ]] && continue
        export "$kv" 2>/dev/null
      done
    }

    """#

    /// Runs on the other Mac as `zsh -fc <this> crook <payload>`.
    static let remoteScript = "emulate -R zsh\n" + resolveClaude + #"""
    typeset -a CROOK_FIELDS
    CROOK_FIELDS=("${(@0)"$(print -rn -- "$1" | /usr/bin/base64 -D)"}")
    CROOK_FIELDS[-1]=()
    CROOK_DIR=$CROOK_FIELDS[1]
    shift CROOK_FIELDS
    cd -- "$CROOK_DIR" 2>/dev/null || exit 91
    crook_resolve_claude
    [[ -n $CROOK_EXE ]] || exit 90
    crook_apply_login_env
    exec "$CROOK_EXE" "${CROOK_FIELDS[@]}"

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
    # Crook may have given up in the moment between that look and this report.
    if [[ -e abandoned ]]; then
      rm -f runner.pid
      exit 0
    fi
    # Claude Code reads Ctrl-C as a key. Should one reach this script anyway,
    # carry on so the ending is still reported. A handler, not an ignore: an
    # ignored signal would stay ignored in the program run below.
    trap : INT

    # This window, so it can be placed beside Crook and closed at the end.
    TTY=$(tty)
    W=""
    if [[ -f window.applescript ]]; then
      W=$(/usr/bin/osascript window.applescript find "$TTY" 2>/dev/null)
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

    # Gone (a cache cleaner, or Crook forgetting a session it gave up on):
    # there is nobody to report to, and the report must not land in the
    # project folder instead.
    cd -- "$S" 2>/dev/null || exit 0
    print -r -- "$st $(( SECONDS - started ))" > exit.tmp && mv -f exit.tmp exit

    close_window() {
      [[ -n $W ]] || return 0
      /usr/bin/perl -MPOSIX -e 'setsid(); exec @ARGV' /usr/bin/osascript "$S/window.applescript" close-when-idle "$W" "$TTY" </dev/null >/dev/null 2>&1 &!
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
      # Not a clean exit, so a Terminal set to close windows when the shell
      # exits cleanly keeps this one open to be read.
      exit $st
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
    				try
    					if (count of tabs of w) is 1 then
    						set t to tab 1 of w
    						if ((tty of t) as text) is target and (busy of t) then return (id of w) as text
    					end if
    				end try
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
    			-- Only a window that is still this session's: one tab, on the
    			-- terminal the runner was given, with nothing running in it.
    			if (count of tabs of w) is not 1 then return ""
    			if busy of tab 1 of w then return ""
    			if (count of argv) > 2 then
    				set t to (tty of tab 1 of w) as text
    				if t is not "" and t is not (item 3 of argv) then return ""
    			end if
    			close w
    		end if
    	end tell
    	return ""
    end run

    """#
}
