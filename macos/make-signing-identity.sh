#!/bin/bash
# Create a stable self-signed code-signing identity (once), so macOS keeps
# Screen Recording permission across rebuilds. Lives outside the repo.
set -e
NAME="Live Poker Solver Dev"
KC="$HOME/Library/Keychains/solver-signing.keychain-db"
PASS="solver-signing-local"

if security find-identity -p codesigning "$HOME/Library/Keychains/solver-signing.keychain-db" 2>/dev/null | grep -q "$NAME"; then
  echo "Identity already exists: $NAME"; exit 0
fi

DIR=$(mktemp -d)
cat > "$DIR/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Live Poker Solver Dev
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -days 3650 -nodes -config "$DIR/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -out "$DIR/dev.p12" -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -passout pass:"$PASS" -name "$NAME" 2>/dev/null

[ -f "$KC" ] || security create-keychain -p "$PASS" "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import "$DIR/dev.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KC"
rm -rf "$DIR"
echo "Created identity: $NAME"
