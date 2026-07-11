#!/bin/bash
# Compiles main.swift into Postit.app (a real double-clickable macOS app).
set -e
cd "$(dirname "$0")"

APP="Postit.app"
BIN="$APP/Contents/MacOS/Postit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# compile - universal (Apple Silicon + Intel), floor macOS 13 so the
# translucent-blur fallback path reaches older Macs
swiftc -O -target arm64-apple-macos13.0  main.swift -o "$BIN-arm64"
swiftc -O -target x86_64-apple-macos13.0 main.swift -o "$BIN-x86_64"
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
    <key>CFBundleVersion</key>         <string>1.1</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Postit</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

echo "Built $APP"

# Install the fresh build into /Applications (the stable home the desktop
# shortcut and login item point at). Edit main.swift, run ./build.sh, done.
pkill -x Postit 2>/dev/null || true
rm -rf "/Applications/$APP"
cp -R "$APP" "/Applications/$APP"
echo "Installed to /Applications/$APP"

# Refresh the ready-to-run copy at the repo root: it ships in the repo so
# Code -> Download ZIP hands people a double-clickable app, no build step.
xattr -cr "$APP"
codesign --force --deep -s - "$APP" 2>/dev/null || true
rm -rf "../$APP"
cp -R "$APP" "../$APP"
echo "Refreshed ../$APP (the committed copy that ships in the download ZIP)"
