#!/bin/zsh
set -eu

identity_name="${SIGN_IDENTITY:-DockClickToggle Local Code Signing}"
root_name="${LOCAL_SIGNING_ROOT_NAME:-DockClickToggle Local Root CA}"
keychain="${KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
tmp_dir="$(/usr/bin/mktemp -d /tmp/dock-click-toggle-signing.XXXXXX)"
p12_password="$(/usr/bin/uuidgen)"

cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

if /usr/bin/security find-identity -v -p codesigning "$keychain" 2>/dev/null |
    /usr/bin/grep -F "\"$identity_name\"" >/dev/null; then
    echo "Code signing identity already exists: $identity_name"
    exit 0
fi

cat > "$tmp_dir/root.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no

[ dn ]
CN = $root_name

[ v3_ca ]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

cat > "$tmp_dir/leaf.conf" <<EOF
[ req ]
distinguished_name = dn
prompt = no

[ dn ]
CN = $identity_name

[ v3_codesign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

/usr/bin/openssl genrsa -out "$tmp_dir/root.key" 4096
/usr/bin/openssl req -x509 -new -nodes \
    -key "$tmp_dir/root.key" \
    -sha256 \
    -days 3650 \
    -out "$tmp_dir/root.crt" \
    -config "$tmp_dir/root.conf"

/usr/bin/openssl genrsa -out "$tmp_dir/leaf.key" 3072
/usr/bin/openssl req -new \
    -key "$tmp_dir/leaf.key" \
    -out "$tmp_dir/leaf.csr" \
    -config "$tmp_dir/leaf.conf"

/usr/bin/openssl x509 -req \
    -in "$tmp_dir/leaf.csr" \
    -CA "$tmp_dir/root.crt" \
    -CAkey "$tmp_dir/root.key" \
    -CAcreateserial \
    -out "$tmp_dir/leaf.crt" \
    -days 3650 \
    -sha256 \
    -extensions v3_codesign \
    -extfile "$tmp_dir/leaf.conf"

/usr/bin/openssl pkcs12 -export \
    -inkey "$tmp_dir/leaf.key" \
    -in "$tmp_dir/leaf.crt" \
    -certfile "$tmp_dir/root.crt" \
    -name "$identity_name" \
    -out "$tmp_dir/identity.p12" \
    -passout "pass:$p12_password"

/usr/bin/security import "$tmp_dir/identity.p12" \
    -k "$keychain" \
    -f pkcs12 \
    -P "$p12_password" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

/usr/bin/security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$keychain" \
    "$tmp_dir/root.crt"

echo "Created local code signing identity: $identity_name"
echo
/usr/bin/security find-identity -v -p codesigning "$keychain" |
    /usr/bin/grep -F "\"$identity_name\"" || true
