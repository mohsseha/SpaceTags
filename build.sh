#!/bin/bash
# Builds build/SpaceTags.app. Usage: ./build.sh [run|install]
# install copies it to /Applications, where it registers itself to launch at login.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SpaceTags.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/SpaceTags" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.spacetags</string>
    <key>CFBundleName</key><string>SpaceTags</string>
    <key>CFBundleExecutable</key><string>SpaceTags</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# A stable local identity keeps the Accessibility grant across rebuilds; ad-hoc signing loses it every time.
IDENTITY="SpaceTags Local Signing"
security find-identity -p codesigning | grep -q "$IDENTITY" || IDENTITY=-
codesign --force --sign "$IDENTITY" "$APP"

if [[ "${1:-}" == "run" ]]; then
    pkill -x SpaceTags 2>/dev/null || true
    open "$APP"
elif [[ "${1:-}" == "install" ]]; then
    pkill -x SpaceTags 2>/dev/null || true
    rm -rf /Applications/SpaceTags.app
    cp -R "$APP" /Applications/SpaceTags.app
    open /Applications/SpaceTags.app
fi
