#!/bin/bash
set -euo pipefail
umask 077

settings="$HOME/Library/Application Support/Chubzik"
identity_file="$settings/signing-fingerprint"
if [[ -s "$identity_file" ]]; then
    printf '%s\n' 'Chubzik already has a local signing identity.'
    exit
fi

temporary=$(mktemp -d)
cleanup() {
    for name in certificate.cnf signing.key signing.pem signing.p12; do
        if [[ -f "$temporary/$name" ]]; then unlink "$temporary/$name"; fi
    done
    rmdir "$temporary"
}
trap cleanup EXIT
archive_password=$(openssl rand -hex 24)
export archive_password
cat > "$temporary/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = subject
prompt = no
x509_extensions = signature
[subject]
CN = Chubzik Local App Signing
[signature]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
CONFIG

openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -config "$temporary/certificate.cnf" -keyout "$temporary/signing.key" -out "$temporary/signing.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$temporary/signing.key" -in "$temporary/signing.pem" \
    -name 'Chubzik Local App Signing' -out "$temporary/signing.p12" -passout env:archive_password
fingerprint=$(openssl x509 -in "$temporary/signing.pem" -sha1 -fingerprint -noout | cut -d= -f2 | tr -d :)
keychain=$(security default-keychain -d user | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/')
[[ -f "$keychain" ]]
security import "$temporary/signing.p12" -f pkcs12 -k "$keychain" -P "$archive_password" -T /usr/bin/codesign
mkdir -p "$settings"
printf '%s\n' "$fingerprint" > "$identity_file"
printf '%s\n' 'Created a Chubzik signing identity in the user keychain.'
