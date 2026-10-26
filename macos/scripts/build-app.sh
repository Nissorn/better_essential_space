#!/bin/zsh
# Assembles dist/BetterEssentialSpace.app from a release build.
# Prefers the full Xcode toolchain when installed (the SwiftUI macro plugin and
# XCTest live there); falls back to Command Line Tools, which can only build
# the Core library — not the app.
set -euo pipefail
cd "$(dirname "$0")/.."

XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
if [[ -d "$XCODE_DEV" ]]; then
  export DEVELOPER_DIR="$XCODE_DEV"
fi

swift build -c release

APP="dist/BetterEssentialSpace.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BetterEssentialSpace "$APP/Contents/MacOS/BetterEssentialSpace"
cp -R .build/release/BetterEssentialSpace_BetterEssentialSpace.bundle "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.nissorn.betteressentialspace</string>
    <key>CFBundleName</key>
    <string>Better Essential Space</string>
    <key>CFBundleDisplayName</key>
    <string>Better Essential Space</string>
    <key>CFBundleExecutable</key>
    <string>BetterEssentialSpace</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
