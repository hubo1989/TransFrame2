#!/usr/bin/env bash
# One-time setup of the GitHub secrets and variable that .github/workflows/release.yml needs.
# Usage: Scripts/setup-release-secrets.sh /path/to/DeveloperID.p12
#
# Before running:
#   1. Keychain Access › login › My Certificates › right-click "Developer ID Application: …" › Export… › save as .p12 and choose
#      a password.
#   2. appleid.apple.com › Sign-In and Security › App-Specific Passwords › create one for "TransFrame notarization".
#   3. `gh auth login` (or `gh auth refresh`) so the GitHub CLI can write repository secrets.
# Nothing secret is printed or written anywhere except to GitHub; temporary files are removed on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

p12="${1:-}"
[[ -f "$p12" ]] || { echo "Usage: $0 /path/to/DeveloperID.p12   (export it from Keychain Access first)"; exit 2; }
command -v gh >/dev/null || { echo "GitHub CLI missing: brew install gh"; exit 1; }

repo="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
echo "Repository: $repo"

retry() { local n; for n in 1 2 3 4 5; do "$@" && return 0; echo "  …retrying ($n)"; sleep 2; done; return 1; }
retry gh api "repos/$repo" --jq .full_name >/dev/null || { echo "GitHub CLI cannot reach $repo — run: gh auth refresh -h github.com"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
team="$(sed -E 's/.*\(([A-Z0-9]{10})\)$/\1/' <<<"$identity")"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo "No Developer ID Application identity in the keychain"; exit 1; }
echo "Signing identity: $identity"

read -r -s -p "Password of the .p12 file: " p12_password; echo
# The .p12 must open with this password and hold this team's Developer ID identity (checked in a throwaway keychain).
check_keychain="$tmp/check.keychain-db"
security create-keychain -p "" "$check_keychain" >/dev/null
if ! security import "$p12" -k "$check_keychain" -P "$p12_password" -T /usr/bin/codesign >/dev/null 2>&1; then
  security delete-keychain "$check_keychain" >/dev/null 2>&1 || true
  echo "The .p12 did not open with that password; nothing was changed."; exit 1
fi
if ! security find-identity -p codesigning "$check_keychain" | grep -q "Developer ID Application: .*($team)"; then
  security delete-keychain "$check_keychain" >/dev/null 2>&1 || true
  echo "The .p12 holds no Developer ID Application identity for team $team; nothing was changed."; exit 1
fi
security delete-keychain "$check_keychain" >/dev/null 2>&1 || true
echo "Certificate file checked: Developer ID Application for team $team."
read -r -p "Apple ID used for notarization (e-mail): " apple_id
read -r -s -p "App-specific password for that Apple ID: " notary_password; echo

echo "Checking the notarization credentials with Apple…"
xcrun notarytool history --apple-id "$apple_id" --password "$notary_password" --team-id "$team" >/dev/null \
  || { echo "Apple rejected these notarization credentials; nothing was changed."; exit 1; }

generate_keys="$(find build/DerivedData ~/Library/Developer/Xcode/DerivedData -path '*artifacts*sparkle*/bin/generate_keys' -type f 2>/dev/null | head -1 || true)"
[[ -n "$generate_keys" ]] || { echo "Sparkle's generate_keys not found — build the app once (Scripts/build.sh Release)"; exit 1; }
echo "Reading the Sparkle private key from the keychain (macOS may ask to allow access)…"
"$generate_keys" --account transframe2 -x "$tmp/sparkle.key" >/dev/null
[[ -s "$tmp/sparkle.key" ]] || { echo "Could not export the Sparkle key (account transframe2)"; exit 1; }
public_key="$(sed -n 's/.*TF_SPARKLE_PUBLIC_KEY: "\(.*\)".*/\1/p' project.yml)"
[[ -n "$public_key" ]] || { echo "TF_SPARKLE_PUBLIC_KEY missing in project.yml"; exit 1; }

set_secret() { echo "  secret $1"; retry gh secret set "$1" --repo "$repo" < "$2" >/dev/null; }
printf '%s' "$p12_password" > "$tmp/p12_password"
printf '%s' "$apple_id" > "$tmp/apple_id"
printf '%s' "$notary_password" > "$tmp/notary_password"
printf '%s' "$team" > "$tmp/team"
base64 -i "$p12" | tr -d '\n' > "$tmp/p12.b64"

echo "Writing repository secrets:"
set_secret DEVELOPER_ID_P12_BASE64 "$tmp/p12.b64"
set_secret DEVELOPER_ID_P12_PASSWORD "$tmp/p12_password"
set_secret APPLE_TEAM_ID "$tmp/team"
set_secret NOTARY_APPLE_ID "$tmp/apple_id"
set_secret NOTARY_PASSWORD "$tmp/notary_password"
set_secret SPARKLE_PRIVATE_KEY "$tmp/sparkle.key"
echo "  variable SPARKLE_PUBLIC_KEY"
retry gh variable set SPARKLE_PUBLIC_KEY --repo "$repo" --body "$public_key" >/dev/null

echo
retry gh secret list --repo "$repo"
echo "Done. Releases now build when a v0.* or v2.* tag is pushed."
