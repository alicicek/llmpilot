#!/bin/bash
# One-time Sparkle EdDSA key setup (owner-run, interactive).
# generate_keys stores the PRIVATE key in your login Keychain — it never
# touches the repo. The PUBLIC key goes into macos/project.yml
# (SUPublicEDKey) and the private key into the SPARKLE_ED_PRIVATE_KEY
# repo secret for the release workflow.
set -euo pipefail

# shellcheck source=scripts/sparkle-fetch.sh
. "$(dirname "$0")/sparkle-fetch.sh" # SPARKLE_VERSION + digest-verified fetch
WORK=$(mktemp -d /tmp/sparkle-keys.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

fetch_sparkle "$WORK"

echo "== generating EdDSA keypair (private key -> login Keychain) =="
"$WORK/bin/generate_keys"

echo
echo "Next steps (manual, in order):"
echo "  1. Put the public key printed above into macos/project.yml"
echo "     (SUPublicEDKey), run 'cd macos && xcodegen generate', commit."
echo "  2. Export the private key for CI:"
echo "       $WORK/bin/generate_keys -x /tmp/sparkle_ed_private_key"
echo "       gh secret set SPARKLE_ED_PRIVATE_KEY < /tmp/sparkle_ed_private_key"
echo "       rm /tmp/sparkle_ed_private_key"
echo "  3. Never commit either key file."
