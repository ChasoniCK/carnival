#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=carnival.app
# Built in a temp dir: this checkout may live in iCloud Drive, which re-adds
# com.apple.FinderInfo behind xattr -c and makes codesign refuse the bundle.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$APP/Contents/MacOS" "$work/$APP/Contents/Resources"
cp carnival.icns "$work/$APP/Contents/Resources/carnival.icns"
swiftc -O -wmo -parse-as-library -target arm64-apple-macos26.0 carnival.swift \
    -o "$work/$APP/Contents/MacOS/carnival" -framework AppKit -framework IOKit
cat > "$work/$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>carnival</string>
	<key>CFBundleIconFile</key><string>carnival</string>
	<key>CFBundleIdentifier</key><string>local.carnival</string>
	<key>CFBundleName</key><string>carnival</string>
	<key>CFBundleShortVersionString</key><string>1.2</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
xattr -cr "$work/$APP"
codesign --force -s - "$work/$APP"
codesign -v "$work/$APP"
rm -rf "$APP"
ditto "$work/$APP" "$APP"
echo "built $APP"
