#!/usr/bin/env bash
# One-time: create a self-signed code-signing identity in the login keychain
# for building Khuluma.app locally. A stable signature keeps macOS privacy
# grants (Microphone, Accessibility) across rebuilds; ad-hoc signatures change
# with every build, which resets them.
#
# Re-running is a no-op while the identity exists. Deleting and recreating it
# changes the signature, so macOS will ask for permissions again.
set -euo pipefail

# The identity keeps its Lowkey-era name: macOS ties the Microphone and
# Accessibility grants to it, so renaming it would ask for them again.
IDENTITY="${KHULUMA_SIGNING_IDENTITY:-${LOWKEY_SIGNING_IDENTITY:-Lowkey Local Code Signing}}"
KEYCHAIN="${KHULUMA_KEYCHAIN:-${LOWKEY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}}"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signing identity already present: $IDENTITY"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass="khuluma-$RANDOM$RANDOM"

cat >"$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1

# macOS's keychain import expects the older PKCS#12 algorithms.
legacy=()
if openssl version | grep -q '^OpenSSL 3'; then legacy=(-legacy); fi
openssl pkcs12 -export ${legacy[@]+"${legacy[@]}"} -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "$IDENTITY" -out "$work/identity.p12" -passout "pass:$pass"

security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Created signing identity: $IDENTITY"
echo "The first build may show a keychain prompt for codesign; choose \"Always Allow\"."
