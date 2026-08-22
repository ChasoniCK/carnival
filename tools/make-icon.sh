#!/bin/bash
# Regenerates carnival.icns from make-icon.swift.
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swiftc -O tools/make-icon.swift -o "$tmp/mkicon" -framework AppKit
"$tmp/mkicon" "$tmp"
set=$tmp/carnival.iconset
mkdir -p "$set"
cp "$tmp/icon_16.png"   "$set/icon_16x16.png"
cp "$tmp/icon_32.png"   "$set/icon_16x16@2x.png"
cp "$tmp/icon_32.png"   "$set/icon_32x32.png"
cp "$tmp/icon_64.png"   "$set/icon_32x32@2x.png"
cp "$tmp/icon_128.png"  "$set/icon_128x128.png"
cp "$tmp/icon_256.png"  "$set/icon_128x128@2x.png"
cp "$tmp/icon_256.png"  "$set/icon_256x256.png"
cp "$tmp/icon_512.png"  "$set/icon_256x256@2x.png"
cp "$tmp/icon_512.png"  "$set/icon_512x512.png"
cp "$tmp/icon_1024.png" "$set/icon_512x512@2x.png"
iconutil -c icns "$set" -o carnival.icns
cp "$tmp/icon_512.png" docs/icon.png
rm -rf "$tmp"
echo "wrote carnival.icns"
