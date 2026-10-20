#!/bin/bash
# creates a self-signed codesigning cert and imports it into the login keychain
# w/o an apple developer account this is what gives a stable signing identity so macOS keeps
# the mic permission across versions. gatekeeper still says "unidentified developer"
#
# usage: scripts/create-signing-cert.sh [backup dir]
# .p12 and its password get written to that dir, back it up. for ci the base64 .p12
# and its password go in secrets HUSH_SIGNING_P12 and HUSH_SIGNING_P12_PASSWORD
set -euo pipefail
NAME="Hush Self-Signed Code Signing"
OUT="${1:-$HOME/Library/Application Support/Hush-signing}"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Le certificat « $NAME » existe déjà dans le trousseau."
    exit 0
fi
mkdir -p "$OUT"
chmod 700 "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Hush (open source)
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(openssl rand -base64 24)"
# p12 format the macOS keychain accepts (legacy algos)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$OUT/hush-signing.p12" -passout "pass:$PASS" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$OUT/hush-signing.p12" -passout "pass:$PASS"
printf '%s\n' "$PASS" > "$OUT/hush-signing.password"
chmod 600 "$OUT"/hush-signing.*
# -T lets codesign use the key w/o an auth prompt
security import "$OUT/hush-signing.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security
echo "Certificat « $NAME » importé."
echo "SAUVEGARDEZ ce dossier (si le certificat est perdu, les utilisateurs devront réautoriser le micro) :"
echo "  $OUT"
openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1
