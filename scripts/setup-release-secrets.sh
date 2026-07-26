#!/usr/bin/env bash
#
# Sets the seven repository secrets the release workflow needs.
#
# Every value is piped to `gh` on stdin rather than passed as an argument, so
# nothing lands in the shell history, the process list, or a file. The .p12 is
# read from a path you supply and is never copied anywhere.
#
# Run it from the repo:  ./scripts/setup-release-secrets.sh ~/Desktop/DeveloperID.p12

set -euo pipefail

P12_PATH="${1:-}"
if [[ -z "$P12_PATH" || ! -f "$P12_PATH" ]]; then
    echo "usage: $0 /path/to/DeveloperID.p12" >&2
    echo >&2
    echo "Export it from Keychain Access: My Certificates -> your Developer ID" >&2
    echo "Application certificate -> right-click -> Export -> .p12" >&2
    exit 1
fi

# These are not secrets — they are embedded in every signed binary you ship — but
# the workflow reads them as secrets, so they are set the same way.
DEFAULT_IDENTITY="Developer ID Application: Jonathan Kizer (8QDNBA629H)"
DEFAULT_TEAM_ID="8QDNBA629H"

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
ACCOUNT="$(gh api user --jq .login)"
echo "Repository: $REPO"
echo "Authenticated as: $ACCOUNT"
read -r -p "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "Aborted."; exit 1; }
echo

set_secret() {   # set_secret NAME  (value on stdin)
    gh secret set "$1" --repo "$REPO"
    echo "  set $1"
}

# 1. The certificate itself.
base64 -i "$P12_PATH" | set_secret BUILD_CERTIFICATE_BASE64

# 2. The password you chose when exporting the .p12.
read -r -s -p "Password you set when exporting the .p12: " P12_PASSWORD; echo
printf '%s' "$P12_PASSWORD" | set_secret P12_PASSWORD
unset P12_PASSWORD

# 3. Throwaway password for the temporary keychain CI creates and discards.
#    Generated rather than invented — it never needs to be known by a human.
openssl rand -base64 24 | tr -d '\n' | set_secret KEYCHAIN_PASSWORD

# 4/5. Identity and team.
read -r -p "Signing identity [$DEFAULT_IDENTITY]: " IDENTITY
printf '%s' "${IDENTITY:-$DEFAULT_IDENTITY}" | set_secret SIGNING_IDENTITY

read -r -p "Team ID [$DEFAULT_TEAM_ID]: " TEAM_ID
printf '%s' "${TEAM_ID:-$DEFAULT_TEAM_ID}" | set_secret APPLE_TEAM_ID

# 6/7. Notarization credentials.
read -r -p "Apple ID email (your Developer Program account): " APPLE_ID
printf '%s' "$APPLE_ID" | set_secret APPLE_ID

echo
echo "App-specific password: appleid.apple.com -> Sign-In and Security ->"
echo "App-Specific Passwords. NOT your Apple ID password."
read -r -s -p "App-specific password: " APPLE_APP_PASSWORD; echo
printf '%s' "$APPLE_APP_PASSWORD" | set_secret APPLE_APP_PASSWORD
unset APPLE_APP_PASSWORD

echo
echo "Done. Verify with:  gh secret list"
echo "Then release with:  git tag v0.1.0 && git push origin v0.1.0"
