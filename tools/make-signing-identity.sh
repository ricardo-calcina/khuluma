#!/usr/bin/env bash
# Keychain-native creation avoids disposable exported private-key files.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/bin/khuluma-lib/identity.sh"
khuluma_reject_obsolete_environment
IDENTITY="${KHULUMA_SIGNING_IDENTITY:-Khuluma Local Code Signing}"
KEYCHAIN="${KHULUMA_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
[[ "$IDENTITY" != "Lowkey Local Code Signing" && "$IDENTITY" != - ]] || { echo "Choose the new Khuluma identity; keep the legacy certificate unchanged." >&2; exit 2; }
cat <<INSTRUCTIONS
Create the local code-signing identity in Keychain Access when the signing stage
is authorized. This helper does not create/import keys or export private files.

1. Open Keychain Access and select the intended keychain: $KEYCHAIN
2. Choose Certificate Assistant > Create a Certificate.
3. Name: $IDENTITY
   Identity Type: Self Signed Root
   Certificate Type: Code Signing
4. Complete creation in that keychain. Keep the private key in Keychain.
5. Rerun tools/build-khuluma-app.sh with this identity after confirming the
   migration/runtime stage is ready. The build fails if the identity is absent.

Keep the existing Lowkey certificate unchanged for other apps and rollback.
A new bundle/signing identity may require macOS permission approval.
INSTRUCTIONS
