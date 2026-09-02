#!/bin/bash
# Regenerate the app icon from its source, Assets/make-icon.swift.
#
#   ./Assets/make-icon.sh          # Crook.iconset/, Crook.icns, Crook.svg
#   ./Assets/make-icon.sh --sheet  # and contact-sheet.png, for judging small sizes
#
# Nothing in the build depends on this running: Crook.icns is committed. Run it
# only when the artwork changes.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf Crook.iconset
xcrun swift make-icon.swift . "$@"
iconutil -c icns Crook.iconset -o Crook.icns
echo "==> $(cd .. && pwd)/Assets/Crook.icns  ($(stat -f%z Crook.icns) bytes)"
