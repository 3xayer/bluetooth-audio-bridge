#!/bin/sh
# Creates a local self-signed code-signing identity "Bluetooth Audio Bridge Local Signing" in the
# login keychain (once per Mac). build.sh signs with it, so rebuilt apps keep the same identity and
# macOS doesn't ask for Bluetooth permission again or drop the login item.
set -e
NAME="Bluetooth Audio Bridge Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."; exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg.cnf" 2>/dev/null
PW=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PW" 2>/dev/null
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PW" -T /usr/bin/codesign
echo "Created \"$NAME\" (valid 10 years). Rebuild with ./build.sh install."
