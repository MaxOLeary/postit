#!/bin/bash
# icon.svg -> Postit.icns (all Dock/Finder sizes). Run from Swift/icon.
set -e
cd "$(dirname "$0")"
swift render.swift icon.svg icon-1024.png
rm -rf Postit.iconset && mkdir Postit.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon-1024.png --out Postit.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2))
  sips -z $d $d icon-1024.png --out Postit.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns Postit.iconset -o Postit.icns
rm -rf Postit.iconset
echo "wrote Postit.icns"
