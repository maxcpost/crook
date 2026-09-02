#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="build/Crook.app"

echo "==> JS bundle"
( cd web && npx esbuild src/editor.js --bundle --format=iife --global-name=CrookEditor \
    --target=safari26 --outfile=dist/editor.js )

echo "==> assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp web/dist/editor.js web/src/editor.html web/src/theme.css "$APP/Contents/Resources/web/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Crook</string>
  <key>CFBundleExecutable</key><string>Crook</string>
  <key>CFBundleIdentifier</key><string>com.newvisiondevgrp.Crook</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsSecureRestorableState</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Markdown</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
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

codesign --force --sign - "$APP" 2>/dev/null || true
echo "==> built $APP"
