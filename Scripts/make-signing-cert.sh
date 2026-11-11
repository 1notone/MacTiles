#!/usr/bin/env bash
# Makes a free, personal code-signing certificate ("MacTiles Local Signing") in your login
# keychain. Builds signed with it look like the same app to macOS every time, so after an update
# the Keychain doesn't ask for your password again to let MacTiles read its service keys.
#
#   make signing-cert          (or ./Scripts/make-signing-cert.sh)
#
# - It stays on this Mac: the private key never leaves your login keychain.
# - It's only for builds you make yourself; it doesn't replace an Apple Developer ID for
#   releases other people download.
# - macOS asks for your password once, to mark the certificate as trusted for code signing.
# - To remove it: Keychain Access → login → My Certificates → "MacTiles Local Signing" → Delete.
set -euo pipefail

NAME="MacTiles Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

has_identity() { grep -q "\"$NAME\"" <<<"$(security find-identity -p codesigning 2>/dev/null || true)"; }

if has_identity; then
  echo "✓ \"$NAME\" already exists. Local builds (make install) use it automatically."
  exit 0
fi

# macOS's own OpenSSL (LibreSSL) writes a .p12 that the Keychain can import; OpenSSL 3 needs -legacy.
OPENSSL=/usr/bin/openssl
LEGACY=()
if "$OPENSSL" version | grep -q '^OpenSSL 3'; then LEGACY=(-legacy); fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

echo "→ Creating \"$NAME\" (valid for 10 years)…"
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/cert.cnf" 2>/dev/null
pass="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "$NAME" -out "$work/identity.p12" -passout "pass:$pass"

echo "→ Adding it to your login keychain…"
# -T lets codesign use the key without asking each time.
security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null

echo "→ Trusting it for code signing (macOS asks for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"

if has_identity; then
  echo "✓ Done. 'make install' now signs MacTiles with \"$NAME\"."
  echo "  The first time the new build reads your service keys, macOS asks once: click Always Allow."
else
  echo "! The certificate was added, but codesign can't see it. Open Keychain Access and check"
  echo "  login → My Certificates → \"$NAME\"."
  exit 1
fi
