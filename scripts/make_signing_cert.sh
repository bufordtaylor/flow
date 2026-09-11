#!/bin/sh
# Create a self-signed "Flow Dev" code signing identity in the login keychain, so bundle.sh can sign
# with a stable identity and macOS keeps the Accessibility grant across rebuilds.
# Run once. macOS will ask for your login password to trust the certificate and to let codesign use the key.
set -e
NAME="Flow Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "'$NAME' already exists."
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/flow.p12" -passout pass:flow -name "$NAME"
security import "$TMP/flow.p12" -k "$KEYCHAIN" -P flow -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing (user trust settings; macOS prompts for your password).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
# Let codesign use the key without a dialog on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true
echo "Created '$NAME'. Rebuild with: make run"
echo "If macOS asks whether codesign may use the key, choose Always Allow."
