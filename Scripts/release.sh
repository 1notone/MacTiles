#!/usr/bin/env bash
# Builds everything for a MacTiles release into build/release/:
#
#   MacTiles-<version>.pkg   macOS Installer package (installs to /Applications, opens MacTiles)
#   MacTiles-<version>.dmg   drag-to-Applications disk image
#   SHA256SUMS.txt
#
# Usage:
#   ./Scripts/release.sh 1.0.0
#
# Signing & notarization (all optional — without them you get an unsigned local build
# that only runs on this Mac without Gatekeeper warnings):
#   APP_IDENTITY        "Developer ID Application: Jane Doe (TEAMID)"
#   INSTALLER_IDENTITY  "Developer ID Installer: Jane Doe (TEAMID)"
#   Notary credentials, one of:
#     NOTARY_PROFILE                                  a profile saved with `xcrun notarytool store-credentials`
#     APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER     App Store Connect API key
#     APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD               Apple ID with an app-specific password
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-}}"
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>   e.g. $0 1.0.0" >&2
  exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: '$VERSION' isn't a version like 1.0.0" >&2
  exit 1
fi
export VERSION
# shellcheck source=paths.sh
source Scripts/paths.sh

APP_IDENTITY="${APP_IDENTITY:--}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
OUT="build/release"                  # final files, in the project
WORK="$BUILD_ROOT/release-work"      # everything is built and signed here, outside iCloud
PKG_ID="io.github.mactiles.MacTiles.pkg"
PKG="$WORK/out/MacTiles-$VERSION.pkg"
DMG="$WORK/out/MacTiles-$VERSION.dmg"

say()  { printf '\n\033[1m→ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }

# ---------- notarization ----------

notary_args=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_API_KEY_PATH:-}" ]; then
  notary_args=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
elif [ -n "${APPLE_ID:-}" ]; then
  notary_args=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
can_notarize() { [ "$APP_IDENTITY" != "-" ] && [ ${#notary_args[@]} -gt 0 ]; }

notarize() {   # notarize <file> ; then staple <stapleTarget>
  local file="$1" target="${2:-$1}"
  say "Notarizing $(basename "$file") (usually 1–5 minutes)…"
  local log="$WORK/notary-$(basename "$file").json"
  if ! xcrun notarytool submit "$file" "${notary_args[@]}" --wait --output-format json > "$log"; then
    cat "$log" >&2
    exit 1
  fi
  local status id
  status=$(/usr/bin/plutil -extract status raw -o - "$log" 2>/dev/null || echo unknown)
  id=$(/usr/bin/plutil -extract id raw -o - "$log" 2>/dev/null || echo "")
  if [ "$status" != "Accepted" ]; then
    echo "Notarization $status. Apple's log:" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${notary_args[@]}" >&2
    exit 1
  fi
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK/out"

# ---------- 1. app ----------

say "Building MacTiles $VERSION"
APP_IDENTITY="$APP_IDENTITY" ./Scripts/build-app.sh

if can_notarize; then
  ditto -c -k --keepParent "$APP" "$WORK/MacTiles.zip"
  notarize "$WORK/MacTiles.zip" "$APP"     # staple the app itself so it passes Gatekeeper offline
else
  warn "Skipping notarization (needs APP_IDENTITY plus notary credentials)."
fi

# ---------- 2. installer package ----------

say "Building installer package"
STAGE="$WORK/pkgroot"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MacTiles.app"

cat > "$WORK/component.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>RootRelativeBundlePath</key><string>MacTiles.app</string>
        <!-- Always install to /Applications, never "upgrade" a copy found elsewhere (e.g. a build folder). -->
        <key>BundleIsRelocatable</key><false/>
        <key>BundleIsVersionChecked</key><false/>
        <key>BundleHasStrictIdentifier</key><true/>
        <key>BundleOverwriteAction</key><string>upgrade</string>
    </dict>
</array>
</plist>
EOF

pkgbuild --root "$STAGE" \
         --component-plist "$WORK/component.plist" \
         --identifier "$PKG_ID" \
         --version "$VERSION" \
         --install-location /Applications \
         --scripts Resources/Installer/scripts \
         "$WORK/MacTiles-component.pkg"

RES="$WORK/installer-resources"
mkdir -p "$RES"
sed "s/__VERSION__/$VERSION/g" Resources/Installer/welcome.html > "$RES/welcome.html"
cp Resources/Installer/conclusion.html "$RES/conclusion.html"
cp LICENSE "$RES/LICENSE.txt"
sed "s/__VERSION__/$VERSION/g" Resources/Installer/Distribution.xml > "$WORK/Distribution.xml"

product_args=(--distribution "$WORK/Distribution.xml" --resources "$RES" --package-path "$WORK")
if [ -n "$INSTALLER_IDENTITY" ]; then
  productbuild "${product_args[@]}" --sign "$INSTALLER_IDENTITY" --timestamp "$PKG"
else
  warn "Installer package is unsigned (set INSTALLER_IDENTITY to sign it)."
  productbuild "${product_args[@]}" "$PKG"
fi
if can_notarize && [ -n "$INSTALLER_IDENTITY" ]; then notarize "$PKG"; fi

# ---------- 3. disk image ----------

say "Building disk image"
DMG_STAGE="$WORK/dmg"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/MacTiles.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "MacTiles $VERSION" -srcfolder "$DMG_STAGE" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
if [ "$APP_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG"
fi
if can_notarize; then notarize "$DMG"; fi

# ---------- 4. verify & checksums ----------

say "Verifying"
codesign --verify --deep --strict "$APP" && echo "  app signature: valid"
if [ "$APP_IDENTITY" != "-" ]; then
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || warn "Gatekeeper would not accept the app yet."
fi
if [ -n "$INSTALLER_IDENTITY" ]; then
  pkgutil --check-signature "$PKG" | sed -n '1,3p' | sed 's/^/  /'
  spctl --assess --type install --verbose=2 "$PKG" 2>&1 | sed 's/^/  /' || warn "Gatekeeper would not accept the package yet."
fi

cp "$PKG" "$DMG" "$OUT/"
(cd "$OUT" && shasum -a 256 "MacTiles-$VERSION.pkg" "MacTiles-$VERSION.dmg" > SHA256SUMS.txt)
rm -rf "$WORK"

say "Done"
ls -lh "$OUT" | sed 's/^/  /'
if ! can_notarize; then
  echo
  warn "This build isn't notarized, so other Macs will block it."
  warn "See RELEASING.md for the one-time Apple Developer setup."
fi
