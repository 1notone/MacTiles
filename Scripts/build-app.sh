#!/usr/bin/env bash
# Builds MacTiles.app for Apple silicon (arm64) into ~/Library/Caches/MacTiles-build (see paths.sh).
#
#   ./Scripts/build-app.sh                       local build, ad-hoc signed
#   VERSION=1.0.0 ./Scripts/build-app.sh         stamp a version
#   APP_IDENTITY="Developer ID Application: Jane Doe (TEAMID)" ./Scripts/build-app.sh
#                                                release build: hardened runtime, secure timestamp
#
# VERSION defaults to the version in Resources/Info.plist; BUILD defaults to the git commit count.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=paths.sh
source Scripts/paths.sh

CONFIG="${CONFIG:-release}"
PLIST_SRC="Resources/Info.plist"
ENTITLEMENTS="Resources/MacTiles.entitlements"
IDENTITY="${APP_IDENTITY:-${SIGN_IDENTITY:--}}"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$3"; }

VERSION="${VERSION:-$(plist_get CFBundleShortVersionString "$PLIST_SRC")}"
VERSION="${VERSION#v}"
if [ -z "${BUILD:-}" ]; then
  BUILD="$(git rev-list --count HEAD 2>/dev/null || plist_get CFBundleVersion "$PLIST_SRC")"
fi

echo "→ Building MacTiles $VERSION ($BUILD), $CONFIG, arm64…"
swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacTiles" "$APP/Contents/MacOS/MacTiles"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plist_set CFBundleShortVersionString "$VERSION" "$APP/Contents/Info.plist"
plist_set CFBundleVersion "$BUILD" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Remove extended attributes (quarantine, Finder info) that would break the signature.
xattr -cr "$APP"

if [ "$IDENTITY" = "-" ]; then
  echo "→ Signing ad-hoc (local use only; set APP_IDENTITY for a distributable build)"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
  echo "→ Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp \
           --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "✓ Built $APP — $VERSION ($BUILD), $(du -sh "$APP" | cut -f1)"
