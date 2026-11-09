#!/bin/bash
# Builds build/SpaceTags.app. Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SpaceTags.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/SpaceTags" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.spacetags</string>
    <key>CFBundleName</key><string>SpaceTags</string>
    <key>CFBundleExecutable</key><string>SpaceTags</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

if [[ "${1:-}" == "run" ]]; then
    pkill -x SpaceTags 2>/dev/null || true
    open "$APP"
fi
