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

# The remote agent is a SEPARATE program. It runs on the other machine, so it is
# compiled for both architectures — the Mac it is pushed to may not be the Mac
# that built it — and shipped as a resource rather than linked into the app.
echo "==> agent (universal)"
AGENT_SRC="Crook/Remote/Agent/crook-agent.swift"
AGENT_TMP=$(mktemp -d)
xcrun swiftc -O -target arm64-apple-macos13.0  -o "$AGENT_TMP/a64" "$AGENT_SRC"
xcrun swiftc -O -target x86_64-apple-macos13.0 -o "$AGENT_TMP/x64" "$AGENT_SRC"
lipo -create -output "$APP/Contents/Resources/crook-agent" "$AGENT_TMP/a64" "$AGENT_TMP/x64"
rm -rf "$AGENT_TMP"

# Sign the agent explicitly, and BEFORE the bundle is signed — signing it after
# would break the bundle's seal over its own resources.
#
# swiftc ad-hoc signs the arm64 slice on its own (arm64 macOS refuses to execute
# an unsigned Mach-O at all, so the linker has no choice). It does NOT sign the
# cross-compiled x86_64 slice, because Intel does not require it. That slice
# therefore shipped unsigned, which happens to run today and is exactly the kind
# of thing a future macOS tightens. Sign both.
codesign --force --sign - "$APP/Contents/Resources/crook-agent"
for arch in arm64 x86_64; do
  codesign --verify --strict --arch $arch "$APP/Contents/Resources/crook-agent" \
    || { echo "!! agent $arch slice unsigned — it will not run on that Mac"; exit 1; }
done

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
  <!-- Projects live where people keep projects, which on most Macs is Desktop
       or Documents — both behind TCC. Without these strings the consent prompt
       is a bare "Crook would like to access files in your Desktop folder" with
       no reason attached, and a prompt with no reason is a prompt people deny.
       ~/.claude itself is not protected; the project folders are. -->
  <key>NSDesktopFolderUsageDescription</key><string>Crook reads and edits the Claude Code files in projects you keep on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Crook reads and edits the Claude Code files in projects you keep in Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Crook reads and edits the Claude Code files in projects you keep in Downloads.</string>
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
  $(find Crook -name '*.swift' -not -path 'Crook/Remote/Agent/*' | sort | tr '\n' ' ') \
  -o "$APP/Contents/MacOS/Crook"

# Strip extended attributes before signing. The copy steps above leave
# com.apple.FinderInfo and com.apple.provenance behind, and codesign refuses
# with "resource fork, Finder information, or similar detritus not allowed".
# This used to be suppressed with 2>/dev/null || true, so every build shipped
# an unsigned bundle whose executable claimed to have sealed resources —
# which Gatekeeper rejects outright, worse than being plainly unsigned.
sign_bundle() {
  xattr -cr "$APP" 2>/dev/null || true
  # xattr -cr walks the tree, but the attribute that actually blocks signing is
  # the one Launch Services keeps re-stamping on the bundle ROOT. Delete it by
  # name as well: -cr has already returned by the time it reappears, and the
  # bundle root is the only place it lands.
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
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
# Three attempts, because the race is with Launch Services and losing it twice
# in a row is possible. One attempt used to be enough until the app had been
# launched from this path; after that it never was.
signed=""
for _ in 1 2 3; do
  if sign_bundle >/dev/null 2>&1 && codesign --verify --strict "$APP" >/dev/null 2>&1; then
    signed=yes; break
  fi
done
if [ -z "$signed" ]; then
  # Last resort, and the one release.sh relies on: a directory nothing has ever
  # launched from cannot have been stamped. Build there and move the result in.
  echo "   (bundle at $APP was stamped by Launch Services; rebuilding via staging)"
  stage=$(mktemp -d)
  ditto "$APP" "$stage/Crook.app"
  xattr -cr "$stage/Crook.app" 2>/dev/null || true
  codesign --force --sign - --timestamp=none "$stage/Crook.app" >/dev/null 2>&1
  rm -rf "$APP"
  ditto "$stage/Crook.app" "$APP"
  rm -rf "$stage"
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
fi
codesign --verify --strict "$APP" >/dev/null 2>&1 \
  || { echo "!! signature invalid — the app will not open on another Mac"; exit 1; }
echo "==> built $APP"
