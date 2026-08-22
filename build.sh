#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=carnival.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -wmo -parse-as-library -target arm64-apple-macos14.0 carnival.swift -o "$APP/Contents/MacOS/carnival" -framework AppKit -framework IOKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>carnival</string>
	<key>CFBundleIdentifier</key><string>local.carnival</string>
	<key>CFBundleName</key><string>carnival</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
