#!/bin/zsh
# Packages dist/BetterEssentialSpace.app into a distributable .dmg with a
# drag-to-Applications layout. Run scripts/build-app.sh first.
#
# Note: the app is ad-hoc signed. Anyone who downloads this .dmg from the
# internet will hit Gatekeeper and must allow it via System Settings >
# Privacy & Security > "Open Anyway" (or `xattr -dr com.apple.quarantine`).
# Notarization would remove that step but needs a paid Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/BetterEssentialSpace.app"
[[ -d "$APP" ]] || { echo "dist/BetterEssentialSpace.app missing — run scripts/build-app.sh first"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGING="dist/dmg-staging"
DMG="dist/BetterEssentialSpace-$VERSION.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Better Essential Space" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
echo "Built: $PWD/$DMG"
