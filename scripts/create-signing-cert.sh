#!/bin/bash
# Crée (une fois) un certificat de signature de code auto-signé pour Hush et l'importe dans le
# trousseau de session. Sans compte Apple Developer, il donne une identité de signature STABLE :
# macOS conserve alors l'autorisation micro d'une version à l'autre (chez vous et chez vos utilisateurs).
# Gatekeeper considère toujours l'app comme « développeur non identifié » (voir README).
#
# Usage : scripts/create-signing-cert.sh [dossier de sauvegarde]
# Produit <dossier>/hush-signing.p12 (+ mot de passe) : À SAUVEGARDER. Pour la CI, le contenu base64 du
# .p12 et son mot de passe vont dans les secrets HUSH_SIGNING_P12 / HUSH_SIGNING_P12_PASSWORD.
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
# Format p12 compatible avec le trousseau macOS (algorithmes « legacy »).
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$OUT/hush-signing.p12" -passout "pass:$PASS" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$OUT/hush-signing.p12" -passout "pass:$PASS"
printf '%s\n' "$PASS" > "$OUT/hush-signing.password"
chmod 600 "$OUT"/hush-signing.*
# -T : codesign peut utiliser la clé sans fenêtre d'autorisation.
security import "$OUT/hush-signing.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security
echo "Certificat « $NAME » importé."
echo "SAUVEGARDEZ ce dossier (si le certificat est perdu, les utilisateurs devront réautoriser le micro) :"
echo "  $OUT"
openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1
