#!/bin/bash
# Compiles main.swift into Postit.app (a real double-clickable macOS app).
set -e
cd "$(dirname "$0")"

APP="Postit.app"
BIN="$APP/Contents/MacOS/Postit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# compile
swiftc -O main.swift -o "$BIN"

# Info.plist so macOS treats it as a proper app
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Postit</string>
    <key>CFBundleDisplayName</key>     <string>Postit</string>
    <key>CFBundleIdentifier</key>      <string>com.maxoleary.postit</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Postit</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
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
