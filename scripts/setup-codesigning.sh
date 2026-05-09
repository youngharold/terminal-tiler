#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing identity in the user's login
# keychain, used by build-app.sh. Stable identity across rebuilds means macOS TCC
# (Accessibility, Login Items) keeps the grant across `./build-app.sh` runs — you
# stop having to re-grant Accessibility every time you update the app.
#
# Run once:  ./scripts/setup-codesigning.sh
# Idempotent: re-running detects the existing identity and exits.

set -euo pipefail

CERT_CN="TermUsher Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -Fq "$CERT_CN"; then
    echo "==> Identity '$CERT_CN' already exists. Nothing to do."
    security find-identity -v -p codesigning | grep -F "$CERT_CN"
    exit 0
fi

echo "==> Creating self-signed code-signing certificate '$CERT_CN'..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[ req ]
prompt             = no
distinguished_name = dn
x509_extensions    = v3

[ dn ]
CN = $CERT_CN

[ v3 ]
extendedKeyUsage = codeSigning
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
EOF

# Generate the key + self-signed cert in PEM. Single x509 step so cert and key
# share the same in-memory keypair.
openssl req -new -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -config "$TMP/openssl.cnf" \
    -extensions v3 \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem"

# Import the private key first, granting codesign + security access without prompts.
echo "==> Importing private key..."
security import "$TMP/key.pem" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild

# Import the cert. The keychain links it to the matching key automatically.
echo "==> Importing certificate..."
security import "$TMP/cert.pem" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign

# Allow codesign to access the private key without prompting on every build.
echo "==> Setting key partition list..."
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "" \
    "$KEYCHAIN" >/dev/null 2>&1 || true

# Export cert to a stable path so the user can run the sudo trust step below.
cp "$TMP/cert.pem" /tmp/termusher-cert.pem

cat <<TIPS

==> Cert and key are imported. ONE manual step left — run this in your terminal
==> (it needs sudo, no GUI prompts):

    sudo security add-trusted-cert -d -r trustRoot -p codeSign \\
      -k /Library/Keychains/System.keychain /tmp/termusher-cert.pem

After that:

    security find-identity -v -p codesigning   # should list "TermUsher Self-Signed"
    ./build-app.sh                              # will now sign with the stable identity

Reinstall the .app, grant Accessibility ONE more time. From then on, every
subsequent build keeps the grant — no more re-granting Accessibility on rebuilds.

To revert the trust later:
    sudo security delete-trusted-cert /tmp/termusher-cert.pem

TIPS
