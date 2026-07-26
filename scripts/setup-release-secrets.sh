#!/usr/bin/env bash
#
# Sets the seven repository secrets the release workflow needs.
#
# Every value is piped to `gh` on stdin rather than passed as an argument, so
# nothing lands in the shell history, the process list, or a file. The .p12 is
# read from a path you supply and is never copied anywhere.
#
# The certificate is verified first — imported into a throwaway keychain using the
# same command CI will use — so a .p12 that cannot actually sign is caught here
# rather than half way through a release six months from now. The signing identity
# and team ID are then read off the certificate itself.
#
# Run from anywhere:
#   ~/code/personal/Strata/scripts/setup-release-secrets.sh ~/Desktop/Certificates.p12

set -euo pipefail

# Work from the repo this script lives in, so it does not matter where it is run.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

P12_PATH="${1:-}"
if [[ -z "$P12_PATH" || ! -f "$P12_PATH" ]]; then
    cat >&2 <<'USAGE'
usage: setup-release-secrets.sh /path/to/certificate.p12

Export the certificate from the Mac that holds it:

  Keychain Access -> My Certificates -> your "Developer ID Application"
  certificate -> right-click -> Export -> .p12 (Keychain Access names it
  Certificates.p12 by default), and set a password when asked.

It must come from My Certificates, which exports the certificate *and its
private key*. A .cer downloaded from developer.apple.com is the public
certificate only and cannot sign anything.
USAGE
    exit 1
fi

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
ACCOUNT="$(gh api user --jq .login)"
echo "Repository:       $REPO"
echo "Authenticated as: $ACCOUNT"
echo "Certificate:      $P12_PATH"
read -r -p "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "Aborted."; exit 1; }
echo

# --- Verify the certificate can actually sign -------------------------------

read -r -s -p "Password you set when exporting the .p12: " P12_PASSWORD; echo

VERIFY_DIR="$(mktemp -d)"
VERIFY_KEYCHAIN="$VERIFY_DIR/verify.keychain-db"
cleanup() {
    security delete-keychain "$VERIFY_KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

VERIFY_PASSWORD="$(openssl rand -base64 16)"
security create-keychain -p "$VERIFY_PASSWORD" "$VERIFY_KEYCHAIN" >/dev/null
security unlock-keychain -p "$VERIFY_PASSWORD" "$VERIFY_KEYCHAIN" >/dev/null

# Same import command the release workflow runs, so this proves that path works.
if ! security import "$P12_PATH" -P "$P12_PASSWORD" -A -t cert -f pkcs12 \
        -k "$VERIFY_KEYCHAIN" >/dev/null 2>&1; then
    echo >&2
    echo "Could not open that .p12 with the password given." >&2
    echo "Either the password is wrong, or the file is not a PKCS#12 bundle." >&2
    exit 1
fi

IDENTITY_LINE="$(security find-identity -v -p codesigning "$VERIFY_KEYCHAIN" \
    | grep 'Developer ID Application' | head -1 || true)"

if [[ -z "$IDENTITY_LINE" ]]; then
    echo >&2
    echo "That .p12 opened, but holds no Developer ID Application signing identity." >&2
    echo >&2
    echo "The usual cause is exporting the certificate without its private key —" >&2
    echo "for example a .cer downloaded from developer.apple.com. Export from" >&2
    echo "Keychain Access -> My Certificates instead, which includes the key." >&2
    exit 1
fi

# e.g.  1) ABC123 "Developer ID Application: Jane Doe (ABCDE12345)"
DETECTED_IDENTITY="$(sed -E 's/.*"(.*)".*/\1/' <<<"$IDENTITY_LINE")"
DETECTED_TEAM_ID="$(sed -E 's/.*\(([A-Z0-9]+)\)"?.*/\1/' <<<"$DETECTED_IDENTITY")"

echo
echo "Verified: $DETECTED_IDENTITY"
echo "Team ID:  $DETECTED_TEAM_ID"
echo

# --- Set the secrets --------------------------------------------------------

set_secret() {   # set_secret NAME  (value on stdin)
    gh secret set "$1" --repo "$REPO"
    echo "  set $1"
}

base64 -i "$P12_PATH" | set_secret BUILD_CERTIFICATE_BASE64
printf '%s' "$P12_PASSWORD" | set_secret P12_PASSWORD
unset P12_PASSWORD

# Throwaway password for the temporary keychain CI creates and discards.
# Generated rather than invented — no human ever needs to know it.
openssl rand -base64 24 | tr -d '\n' | set_secret KEYCHAIN_PASSWORD

# Read off the certificate above; neither is really a secret (both are embedded in
# every binary you ship) but the workflow reads them as secrets.
printf '%s' "$DETECTED_IDENTITY" | set_secret SIGNING_IDENTITY
printf '%s' "$DETECTED_TEAM_ID" | set_secret APPLE_TEAM_ID

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
