#!/bin/bash
# Compiles main.swift into Postit.app (a real double-clickable macOS app).
set -e
cd "$(dirname "$0")"

APP="Postit.app"
BIN="$APP/Contents/MacOS/Postit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# compile - universal (Apple Silicon + Intel), floor macOS 11 so the
# translucent-blur fallback path reaches older Macs (SF Symbols, the oldest
# API the app leans on, arrived in 11 - Big Sur and Monterey Intel machines
# run the download ZIP as-is)
swiftc -O -target arm64-apple-macos11.0  main.swift -o "$BIN-arm64"
swiftc -O -target x86_64-apple-macos11.0 main.swift -o "$BIN-x86_64"
lipo -create -output "$BIN" "$BIN-arm64" "$BIN-x86_64"
rm "$BIN-arm64" "$BIN-x86_64"

# Info.plist so macOS treats it as a proper app
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Postit</string>
    <key>CFBundleDisplayName</key>     <string>Postit</string>
    <key>CFBundleIdentifier</key>      <string>com.maxoleary.postit</string>
    <key>CFBundleVersion</key>         <string>1.2</string>
    <key>CFBundleShortVersionString</key><string>1.2</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Postit</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

echo "Built $APP"

# Sign before installing. macOS remembers privacy grants (Desktop, Downloads,
# etc.) by code signature, and an ad-hoc signature changes on every build -
# which resets those permissions after each rebuild. A local "Postit Dev"
# certificate keeps the signature stable so grants stick; fall back to ad-hoc
# on machines without it (e.g. building from a ZIP download).
#
# Signing happens in a temp dir because this repo lives in an iCloud-synced
# folder: fileproviderd re-stamps Finder metadata between cleanup and signing,
# and codesign rejects the bundle ("Finder information ... not allowed").
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/$APP"
xattr -cr "$STAGE/$APP"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Postit Dev"'; then
    codesign --force -s "Postit Dev" "$STAGE/$APP"
else
    codesign --force -s - "$STAGE/$APP"
fi

# Install the fresh signed build into /Applications (the stable home the
# desktop shortcut and login item point at). Edit main.swift, ./build.sh, done.
pkill -x Postit 2>/dev/null || true
rm -rf "/Applications/$APP"
cp -R "$STAGE/$APP" "/Applications/$APP"
echo "Installed to /Applications/$APP"

# Refresh the ready-to-run copy at the repo root: it ships in the repo so
# Code -> Download ZIP hands people a double-clickable app, no build step.
rm -rf "../$APP"
cp -R "$STAGE/$APP" "../$APP"
echo "Refreshed ../$APP (the committed copy that ships in the download ZIP)"
