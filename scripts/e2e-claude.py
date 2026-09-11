#!/usr/bin/env python3
"""Edit with Claude, end to end, on a real Mac.

The unit suites prove every decision Edit with Claude makes. They cannot prove
the parts that only exist on a real machine: Terminal opening, Claude Code
running, the file reloading in Crook, windows landing beside each other. This
drives one real session through a build of Crook compiled with its self-test
and photographs Crook's and Terminal's windows (only those) at each step.

    CROOK_SWIFT_FLAGS="-D CROOK_E2E" CROOK_BUILD_DIR=/tmp/crook-e2e ./scripts/build.sh
    python3 scripts/e2e-claude.py /tmp/crook-e2e/Crook.app /path/to/scratch/CLAUDE.md run-name \\
        "CROOK_E2E_CLAUDE=Change the Notes heading to Remarks. Change nothing else." \\
        CROOK_E2E_END=session            # or exit (types /exit into Terminal), or quit
        [CROOK_E2E_LINES=5-9] [CROOK_E2E_QUIET=12] ["CROOK_E2E_FRAME=x y w h"]
        [CROOK_E2E_PHASE=reattach]       # after a quit run: pick the session up and end it

Use a scratch file in a folder Claude Code already trusts, or the session waits
at the trust question. Output: $TMPDIR/crook-e2e-runs/<run-name>/ (log and PNGs).
Afterwards, unregister and delete the E2E build: two registered copies of the
same bundle id let `open -b` pick the wrong one.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

app, file, name = sys.argv[1], sys.argv[2], sys.argv[3]
env_pairs = sys.argv[4:]
out = os.path.join(tempfile.gettempdir(), "crook-e2e-runs", name)
os.makedirs(out, exist_ok=True)
log = os.path.join(out, "crook.log")
open(log, "w").close()

cmd = ["open", "-n", "-a", app, "--stderr", log, "--stdout", os.path.join(out, "stdout.log")]
for kv in env_pairs:
    cmd += ["--env", kv]
subprocess.run(cmd + ["--args", file], check=True)

start, pos, folder = time.time(), 0, None
finished = seen_crook = False
while time.time() - start < 600:
    time.sleep(0.3)
    with open(log, errors="replace") as f:
        f.seek(pos)
        chunk = f.read()
        pos = f.tell()
    for line in chunk.splitlines():
        m = re.search(r"Crook: E2E (.*)$", line)
        if not m:
            continue
        msg = m.group(1)
        print(f"[{time.time() - start:6.1f}] {msg}", flush=True)
        found = re.search(r"folder=(\S+)", msg)
        if found:
            folder = found.group(1)
        if msg.startswith("shot "):
            parts = msg.split()
            for wid in [i for i in parts[2:] if i != "0"]:
                subprocess.run(["screencapture", "-x", "-o", "-l", wid, os.path.join(out, f"{parts[1]}-{wid}.png")])
        if msg.startswith("send-exit") and folder:
            # Typing /exit into the session's window. Sent from inside Terminal,
            # so Terminal is scripting itself and nobody is asked for permission.
            helper = os.path.join(out, "send-exit.command")
            with open(helper, "w") as h:
                h.write(f"""#!/bin/zsh
/usr/bin/osascript -e 'tell application "Terminal" to do script "/exit" in window id {msg.split()[1]}'
W=$(/usr/bin/osascript {folder}/window.applescript find "$(tty)")
/usr/bin/perl -MPOSIX -e 'setsid(); exec @ARGV' /usr/bin/osascript {folder}/window.applescript close-when-idle "$W" </dev/null >/dev/null 2>&1 &!
exit 0
""")
            os.chmod(helper, 0o700)
            subprocess.run(["open", "-a", "Terminal", helper])
        if msg in ("finished", "no-document", "reattach no-session", "quitting-mid-session"):
            finished = True
    running = subprocess.run(["pgrep", "-f", app + "/Contents/MacOS/Crook"], capture_output=True).returncode == 0
    seen_crook = seen_crook or running
    if (finished or seen_crook) and not running and time.time() - start > 5:
        break
print(f"done after {time.time() - start:.0f}s; output in {out}")
