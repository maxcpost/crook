#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# Where the bundle is assembled. release.sh overrides this to build somewhere
# nothing has ever launched from — see the signing note further down for why
# that matters.
APP="${CROOK_BUILD_DIR:-build}/Crook.app"

echo "==> JS bundle"
( cd web && npx esbuild src/editor.js --bundle --format=iife --global-name=CrookEditor \
    --target=safari26 --outfile=dist/editor.js )

echo "==> assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp web/dist/editor.js web/src/editor.html web/src/theme.css "$APP/Contents/Resources/web/"
cp Assets/Crook.icns "$APP/Contents/Resources/Crook.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Crook</string>
  <key>CFBundleExecutable</key><string>Crook</string>
  <key>CFBundleIconFile</key><string>Crook</string>
  <key>CFBundleIdentifier</key><string>com.newvisiondevgrp.Crook</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. See THIRD-PARTY.md for bundled components.</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsSecureRestorableState</key><true/>
  <!-- Editor, not Viewer: Crook writes these files, and the role is what tells
       Launch Services whether saving is a thing this app does.

       Alternate is the deliberate half. Rank Owner would make Crook the default
       for every .md on the machine the moment someone drags it to Applications
       — a small free tool has no business seizing a file type the user already
       assigned. Alternate keeps Crook in the Open With list and out of the
       default slot.

       The "*" extension is what lets NSDocumentController open a file with an
       unusual or absent extension; it is safe to claim only BECAUSE the rank is
       Alternate. Claiming "*" at Owner rank is how an editor becomes the thing
       that opens your .psd. -->
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Markdown</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string><string>public.plain-text</string><string>public.json</string><string>public.text</string></array>
    <key>NSDocumentClass</key><string>CrookDocument</string>
    <key>CFBundleTypeExtensions</key><array><string>md</string><string>markdown</string><string>txt</string><string>json</string><string>*</string></array>
  </dict></array>
</dict></plist>
PLIST

echo "==> swiftc"
xcrun swiftc -target arm64-apple-macos26.0 \
  -module-name Crook \
  -O -whole-module-optimization \
  $(find Crook -name '*.swift' | sort | tr '\n' ' ') \
  -o "$APP/Contents/MacOS/Crook"

# Strip extended attributes before signing. The copy steps above leave
# com.apple.FinderInfo and com.apple.provenance behind, and codesign refuses
# with "resource fork, Finder information, or similar detritus not allowed".
# This used to be suppressed with 2>/dev/null || true, so every build shipped
# an unsigned bundle whose executable claimed to have sealed resources —
# which Gatekeeper rejects outright, worse than being plainly unsigned.
sign_bundle() {
  xattr -cr "$APP" 2>/dev/null || true
  codesign --force --sign - --timestamp=none "$APP" 2>&1
}
# Retry once: anything touching the bundle between the strip and the sign
# re-adds com.apple.FinderInfo and codesign then refuses. (com.apple.provenance
# survives xattr -cr — it is system-managed — but does not block signing.)
#
# Worth knowing, because it looks like a bug the first time: LAUNCHING the app
# invalidates its own signature. Launch Services writes com.apple.FinderInfo to
# the bundle root on registration, so a build that verified clean fails
# --strict a moment after you double-click it. Locally that is harmless. It is
# not harmless when packaging, which is why release.sh builds into a directory
# nothing has launched from and verifies the EXTRACTED copy rather than this
# one — the bytes in the zip are the only ones that matter.
sign_bundle >/dev/null 2>&1 || sign_bundle
codesign --verify --strict "$APP" >/dev/null 2>&1 \
  || { echo "!! signature invalid — the app will not open on another Mac"; exit 1; }
echo "==> built $APP"
