#!/usr/bin/env bash
# Builds meTiles — the Mac App Store edition of MacTiles — and packages it for upload.
#
#   make appstore              (or ./Scripts/appstore.sh [version])
#
# Output: build/appstore/meTiles-<version>.pkg, signed and ready for Apple's Transporter app.
#
# One-time setup (see RELEASING.md → "Mac App Store (meTiles)"):
#   - certificates "Apple Distribution" and "3rd Party Mac Developer Installer" (Mac Installer
#     Distribution) in your login keychain
#   - a Mac App Store provisioning profile for the App ID, saved as
#     AppStore/meTiles.provisionprofile (git ignores it: it carries your team's name)
#
# Optional overrides:
#   APPSTORE_PROFILE            path to the provisioning profile
#   APPSTORE_APP_IDENTITY       e.g. "Apple Distribution: Jane Doe (TEAMID)"
#   APPSTORE_INSTALLER_IDENTITY e.g. "3rd Party Mac Developer Installer: Jane Doe (TEAMID)"
#   BUILD                       build number (defaults to the git commit count; must go up with every upload)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=paths.sh
source Scripts/paths.sh

NAME="meTiles"
PLIST_SRC="Resources/Info.plist"
ENTITLEMENTS_SRC="Resources/AppStore/meTiles.entitlements"
PROFILE="${APPSTORE_PROFILE:-AppStore/meTiles.provisionprofile}"
SCRATCH_STORE="$BUILD_ROOT/swiftpm-appstore"
WORK="$BUILD_ROOT/appstore"
STORE_APP="$WORK/$NAME.app"
OUT="build/appstore"

say()  { printf '\n\033[1m→ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$3"; }
plist_add() { /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$4"; }

VERSION="${1:-${VERSION:-$(plist_get CFBundleShortVersionString "$PLIST_SRC")}}"
VERSION="${VERSION#v}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || plist_get CFBundleVersion "$PLIST_SRC")}"

# --- What we need ------------------------------------------------------------------------
[ -f "$PROFILE" ] || fail "No provisioning profile at $PROFILE. Download your Mac App Store profile from developer.apple.com and save it there (see RELEASING.md)."

profile_plist="$(mktemp)"
trap 'rm -f "$profile_plist"' EXIT
security cms -D -i "$PROFILE" > "$profile_plist" 2>/dev/null || fail "Couldn't read $PROFILE. Download the profile again from developer.apple.com."
# (Every lookup below falls back to an empty value, so a missing value reaches its own error message
# instead of silently stopping the script under "set -e".)
TEAM_ID="$(plist_get 'TeamIdentifier:0' "$profile_plist" 2>/dev/null)" || TEAM_ID=""
APP_ID_FULL="$(plist_get 'Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null)" || APP_ID_FULL=""
[ -n "$TEAM_ID" ] && [ -n "$APP_ID_FULL" ] ||
  fail "$PROFILE isn't a Mac App Store provisioning profile. Create one of type \"Mac App Store Connect\" (see RELEASING.md)."
BUNDLE_ID="${APP_ID_FULL#"$TEAM_ID".}"
[ -n "$BUNDLE_ID" ] && [ "$BUNDLE_ID" != "*" ] ||
  fail "The provisioning profile must be for one explicit App ID (like io.github.mactiles.metiles), not a wildcard."

# Lists what's in the keychain when a certificate is missing, so it's clear what to fix.
show_certificates() {
  local found
  found="$(security find-identity -v 2>/dev/null | grep -E 'Apple Distribution|Mac Developer|Installer|Developer ID' || true)"
  if [ -n "$found" ]; then
    printf '\nSigning certificates in your keychain (this profile is for team %s):\n%s\n' "$TEAM_ID" "$found" >&2
  else
    printf '\nThere are no usable signing certificates in your keychain. In Xcode: Settings → Accounts → your team → Manage Certificates… → +.\n' >&2
  fi
}

APP_IDENTITY="${APPSTORE_APP_IDENTITY:-}"
if [ -z "$APP_IDENTITY" ]; then
  APP_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
    grep -Eo '"(Apple Distribution|3rd Party Mac Developer Application): [^"]*\('"$TEAM_ID"'\)"' | head -1 | tr -d '"' || true)"
fi
[ -n "$APP_IDENTITY" ] || { show_certificates; fail "No \"Apple Distribution\" certificate for team $TEAM_ID in your keychain (see RELEASING.md)."; }

INSTALLER_IDENTITY="${APPSTORE_INSTALLER_IDENTITY:-}"
if [ -z "$INSTALLER_IDENTITY" ]; then
  INSTALLER_IDENTITY="$(security find-identity -v 2>/dev/null |
    grep -Eo '"(3rd Party Mac Developer Installer|Mac Installer Distribution): [^"]*\('"$TEAM_ID"'\)"' | head -1 | tr -d '"' || true)"
fi
[ -n "$INSTALLER_IDENTITY" ] || { show_certificates; fail "No \"Mac Installer Distribution\" (3rd Party Mac Developer Installer) certificate for team $TEAM_ID in your keychain (see RELEASING.md)."; }

echo "meTiles $VERSION ($BUILD) · $BUNDLE_ID · team $TEAM_ID"

# --- Build ------------------------------------------------------------------------------
say "Building the App Store edition (APPSTORE)"
swift build -c release --arch arm64 --scratch-path "$SCRATCH_STORE" -Xswiftc -DAPPSTORE
BIN_DIR="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH_STORE" -Xswiftc -DAPPSTORE --show-bin-path)"

rm -rf "$WORK"
mkdir -p "$STORE_APP/Contents/MacOS" "$STORE_APP/Contents/Resources"
cp "$BIN_DIR/MacTiles" "$STORE_APP/Contents/MacOS/$NAME"
cp Resources/AppIcon.icns "$STORE_APP/Contents/Resources/AppIcon.icns"
# Same Info.plist, with the App Store name, identifier and the keys App Store Connect asks for.
sed 's/MacTiles/meTiles/g' "$PLIST_SRC" > "$STORE_APP/Contents/Info.plist"
info="$STORE_APP/Contents/Info.plist"
plist_set CFBundleExecutable "$NAME" "$info"
plist_set CFBundleName "$NAME" "$info"
plist_set CFBundleDisplayName "$NAME" "$info"
plist_set CFBundleIdentifier "$BUNDLE_ID" "$info"
plist_set CFBundleShortVersionString "$VERSION" "$info"
plist_set CFBundleVersion "$BUILD" "$info"
plist_add ITSAppUsesNonExemptEncryption bool false "$info"     # only standard HTTPS
printf 'APPL????' > "$STORE_APP/Contents/PkgInfo"
cp "$PROFILE" "$STORE_APP/Contents/embedded.provisionprofile"
xattr -cr "$STORE_APP"

# --- Sign -------------------------------------------------------------------------------
say "Signing with $APP_IDENTITY"
entitlements="$WORK/meTiles.entitlements"
cp "$ENTITLEMENTS_SRC" "$entitlements"
plist_add com.apple.application-identifier string "$TEAM_ID.$BUNDLE_ID" "$entitlements"
plist_add com.apple.developer.team-identifier string "$TEAM_ID" "$entitlements"
codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$APP_IDENTITY" "$STORE_APP"
codesign --verify --strict --verbose=2 "$STORE_APP"
signed_entitlements="$(codesign -d --entitlements - "$STORE_APP" 2>/dev/null || true)"
grep -q "com.apple.security.app-sandbox" <<<"$signed_entitlements" || fail "The app isn't sandboxed."

# --- Package ----------------------------------------------------------------------------
say "Packaging for App Store Connect"
mkdir -p "$OUT"
PKG="$OUT/$NAME-$VERSION.pkg"
rm -f "$PKG"
productbuild --component "$STORE_APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
pkgutil --check-signature "$PKG" | sed -n '1,3p'

say "Done"
echo "  $PKG"
echo
echo "Next: open Transporter, sign in with your Apple ID, drag the .pkg in and click Deliver."
echo "Then in App Store Connect: pick build $BUILD for version $VERSION and submit it for review."
