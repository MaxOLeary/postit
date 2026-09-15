#!/bin/bash
# Compiles main.swift into Postit.app, signs it with the hardened runtime,
# installs to /Applications. `./build.sh --ship` also refreshes the committed
# copy at the repo root, zips it, checks it the way Gatekeeper will, notarizes
# when it can, and uploads it to the GitHub release.
set -e
cd "$(dirname "$0")"

APP="Postit.app"
VERSION="$(cat ../VERSION)"
BIN="$APP/Contents/MacOS/Postit"
REPO="MaxOLeary/postit"
SHIP=0
[ "${1:-}" = "--ship" ] && SHIP=1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp icon/Postit.icns "$APP/Contents/Resources/Postit.icns"   # regenerate with icon/make-icns.sh

# Universal (Apple Silicon + Intel), floor macOS 11 so the translucent-blur
# fallback path reaches older Macs (SF Symbols, the oldest API the app leans
# on, arrived in 11).
swiftc -O -target arm64-apple-macos11.0  main.swift -o "$BIN-arm64"
swiftc -O -target x86_64-apple-macos11.0 main.swift -o "$BIN-x86_64"
lipo -create -output "$BIN" "$BIN-arm64" "$BIN-x86_64"
rm "$BIN-arm64" "$BIN-x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Postit</string>
    <key>CFBundleDisplayName</key>     <string>Postit</string>
    <key>CFBundleIdentifier</key>      <string>com.maxoleary.postit</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Postit</string>
    <key>CFBundleIconFile</key>       <string>Postit</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
    <!-- Accept markdown / plain-text files (Finder "Open With…", open -a).
         Rank Alternate so Postit never becomes the system default for .md. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key> <string>Markdown or plain text</string>
            <key>CFBundleTypeRole</key> <string>Viewer</string>
            <key>LSHandlerRank</key>    <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
echo "Built $APP $VERSION"

# Identity: Developer ID if this Mac has one, else the self-signed Postit Dev
# cert, else ad-hoc. macOS keys privacy grants (Desktop, Downloads, etc.) to
# the signature, so a stable cert keeps them across rebuilds; ad-hoc resets
# them every build and Gatekeeper treats it as malware, so it must never ship.
ID="$(security find-identity -v -p codesigning 2>/dev/null \
      | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
if [ -z "$ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Postit Dev"'; then
    ID="Postit Dev"
fi
if [ -z "$ID" ]; then
    ID="-"
    echo "WARNING: no signing identity found, signing ad-hoc. Fine for local use." >&2
    echo "WARNING: an ad-hoc build must never be shipped (macOS shows Malware Blocked)." >&2
    if [ "$SHIP" = 1 ]; then
        echo "Refusing --ship with an ad-hoc signature." >&2
        exit 1
    fi
fi
echo "Signing identity: $ID"

# A trusted timestamp only makes sense on a Developer ID signature; Apple's
# timestamp server rejects self-signed certs.
TS="--timestamp=none"
case "$ID" in "Developer ID"*) TS="--timestamp" ;; esac

# Sign a copy in a temp dir so the build product in Swift/ stays unsigned and
# no Finder metadata sneaks into the seal.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/$APP"
xattr -cr "$STAGE/$APP"

# Hardened runtime is required for notarization. Postit needs no entitlements.
codesign --force --options runtime $TS -s "$ID" "$STAGE/$APP"

install_app() {
    pkill -x Postit 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$1" "/Applications/$APP"
    echo "Installed to /Applications/$APP"
    # Silent on success. A broken seal here is a broken seal for everyone.
    codesign --verify --deep --strict "/Applications/$APP"
    echo "codesign verify: OK"
    codesign -dv --verbose=2 "/Applications/$APP" 2>&1 | grep -E '^Authority=|flags=' || true
    # Always `open -a`: exec'ing the binary breaks the menu bar icon for the session.
    open -a "/Applications/$APP"
}
install_app "$STAGE/$APP"

[ "$SHIP" = 1 ] || exit 0

# ---- ship ------------------------------------------------------------------

# The copy at the repo root is committed so Code -> Download ZIP also gives a
# double-clickable app. Off by default so building from a clone stays clean.
refresh_root() {
    rm -rf "../$APP"
    cp -R "$STAGE/$APP" "../$APP"
    echo "Refreshed ../$APP"
}
refresh_root

make_zip() {
    rm -f "$STAGE/Postit.zip"
    ditto -c -k --keepParent --norsrc --noextattr "$STAGE/$APP" "$STAGE/Postit.zip"
}
make_zip

# Gatekeeper dry run: a quarantined copy is what a Safari download looks like.
# `rejected, origin=<identity>` is the ordinary Open Anyway case; `accepted`
# means notarized. `revoked` means Malware Blocked, which nobody can click
# past, so it is fatal.
SIM="$(mktemp -d)"
ditto "$STAGE/$APP" "$SIM/$APP"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$SIM/$APP"
set +e
VERDICT="$(spctl -a -vv -t exec "$SIM/$APP" 2>&1)"
SPCTL_EXIT=$?
set -e
rm -rf "$SIM"
echo "spctl verdict (exit $SPCTL_EXIT):"
echo "$VERDICT" | sed 's/^/    /'
if echo "$VERDICT" | grep -qi 'revoked'; then
    echo "Gatekeeper says revoked. Do not ship this build." >&2
    exit 1
fi

# Notarize when there is a Developer ID and stored credentials
# (`xcrun notarytool store-credentials notary`). Staple so the app passes
# Gatekeeper offline, then re-zip because the ticket lives inside the bundle.
case "$ID" in
"Developer ID"*)
    if xcrun notarytool history --keychain-profile notary >/dev/null 2>&1; then
        xcrun notarytool submit "$STAGE/Postit.zip" --keychain-profile notary --wait
        xcrun stapler staple "$STAGE/$APP"
        xcrun stapler validate "$STAGE/$APP"
        make_zip
        install_app "$STAGE/$APP"
        refresh_root
    else
        echo "Developer ID present but no 'notary' keychain profile; skipping notarization."
    fi
    ;;
*)
    echo "Not notarized: no Developer ID on this Mac."
    ;;
esac

# One rolling release named `latest`; the download URL never changes.
if gh release view latest -R "$REPO" >/dev/null 2>&1; then
    gh release upload latest "$STAGE/Postit.zip" -R "$REPO" --clobber
else
    gh release create latest "$STAGE/Postit.zip" -R "$REPO" --title Postit \
        --notes "Unzip, double-click Postit. Always the newest build."
fi

trap - EXIT   # keep the zip around
echo "Zip:      $STAGE/Postit.zip"
echo "Download: https://github.com/$REPO/releases/latest/download/Postit.zip"
echo "Commit ../$APP with the code: git add ../$APP && git commit && git push"
