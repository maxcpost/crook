#!/bin/bash
# Produce the artifact people download: a zipped, signed Crook.app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\(.*\)<\/string>.*/\1/p' scripts/build.sh | head -1)
OUT="dist"
rm -rf "$OUT"; mkdir -p "$OUT"

# Build somewhere nothing has ever launched from. A bundle that has been run
# carries com.apple.FinderInfo, which invalidates its signature, and packaging
# that produces a download that fails Gatekeeper on arrival.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> building Crook $VERSION"
CROOK_BUILD_DIR="$STAGE" ./scripts/build.sh >/dev/null

echo "==> verifying the signature"
codesign --verify --strict --verbose "$STAGE/Crook.app" 2>&1 | sed 's/^/    /'

# ditto rather than zip: it preserves the bundle's symlinks, resource forks and
# the signature. A plain `zip` can break the seal and the app then will not open
# on the other side.
echo "==> packaging"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Crook.app" "$OUT/Crook-$VERSION.zip"

# The real gate. Everything above verified a bundle on this machine; this
# verifies what a stranger actually receives, by unpacking the zip the way
# their browser will and checking THAT signature. If this passes, the download
# opens on their Mac.
echo "==> verifying the extracted artifact"
CHECK=$(mktemp -d)
ditto -x -k "$OUT/Crook-$VERSION.zip" "$CHECK"
codesign --verify --strict --deep --verbose "$CHECK/Crook.app" 2>&1 | sed 's/^/    /'

# spctl WILL say "rejected", and that is the correct result, not a failure.
# It reports whether Gatekeeper would launch this without asking, and only
# notarised builds get that. Ad-hoc signing buys one thing: the "Open Anyway"
# button works. A broken or absent signature does not even get that far, which
# is the distinction this whole script exists to protect.
if spctl -a -t exec "$CHECK/Crook.app" >/dev/null 2>&1; then
  echo "    gatekeeper: accepted (notarised)"
else
  echo "    gatekeeper: rejected — expected; ad-hoc signed, not notarised."
  echo "                first launch needs System Settings > Privacy & Security > Open Anyway."
fi
rm -rf "$CHECK"

echo
echo "    $OUT/Crook-$VERSION.zip  ($(du -h "$OUT/Crook-$VERSION.zip" | cut -f1))"
echo
echo "Attach that to a GitHub release. Because it is ad-hoc signed rather than"
echo "notarised, the first launch needs one step from the user — the README"
echo "explains it, and so should the release notes."
