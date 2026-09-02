#!/bin/bash
# Produce the artifact people download: a zipped, signed Crook.app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\(.*\)<\/string>.*/\1/p' scripts/build.sh | head -1)
OUT="dist"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> building Crook $VERSION"
./scripts/build.sh >/dev/null

echo "==> verifying the signature"
codesign --verify --strict --verbose build/Crook.app 2>&1 | sed 's/^/    /'

# ditto rather than zip: it preserves the bundle's symlinks, resource forks and
# the signature. A plain `zip` can break the seal and the app then will not open
# on the other side.
echo "==> packaging"
ditto -c -k --sequesterRsrc --keepParent build/Crook.app "$OUT/Crook-$VERSION.zip"

echo
echo "    $OUT/Crook-$VERSION.zip  ($(du -h "$OUT/Crook-$VERSION.zip" | cut -f1))"
echo
echo "Attach that to a GitHub release. Because it is ad-hoc signed rather than"
echo "notarised, the first launch needs one step from the user — the README"
echo "explains it, and so should the release notes."
