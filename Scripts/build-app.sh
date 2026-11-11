#!/usr/bin/env bash
# Builds MacTiles.app for Apple silicon (arm64) into ~/Library/Caches/MacTiles-build (see paths.sh).
#
#   ./Scripts/build-app.sh                       local build (see "Signing" below)
#   VERSION=1.0.0 ./Scripts/build-app.sh         stamp a version
#   APP_IDENTITY="Developer ID Application: Jane Doe (TEAMID)" ./Scripts/build-app.sh
#                                                release build: hardened runtime, secure timestamp
#
# Signing: APP_IDENTITY wins. Otherwise, if you've made a personal signing certificate with
# `make signing-cert`, local builds use it, so the Keychain recognises each new build as the same
# app and doesn't ask for your password again after updates. Without either, builds are ad-hoc.
#
# VERSION defaults to the version in Resources/Info.plist; BUILD defaults to the git commit count.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=paths.sh
source Scripts/paths.sh

CONFIG="${CONFIG:-release}"
PLIST_SRC="Resources/Info.plist"
ENTITLEMENTS="Resources/MacTiles.entitlements"
LOCAL_IDENTITY="MacTiles Local Signing"     # made by Scripts/make-signing-cert.sh
IDENTITY="${APP_IDENTITY:-${SIGN_IDENTITY:-}}"
if [ -z "$IDENTITY" ]; then
  identities="$(security find-identity -p codesigning 2>/dev/null || true)"
  if grep -q "\"$LOCAL_IDENTITY\"" <<<"$identities"; then
    IDENTITY="$LOCAL_IDENTITY"
  else
    IDENTITY="-"
  fi
fi

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
  echo "→ Signing ad-hoc (local use only; run 'make signing-cert' once so updates keep Keychain access)"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
elif [ "$IDENTITY" = "$LOCAL_IDENTITY" ]; then
  # A personal certificate: same signature identity every build, for this Mac only.
  echo "→ Signing with your personal certificate ($LOCAL_IDENTITY)"
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  echo "→ Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp \
           --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "✓ Built $APP — $VERSION ($BUILD), $(du -sh "$APP" | cut -f1)"
