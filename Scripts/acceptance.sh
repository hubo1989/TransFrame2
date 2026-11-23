#!/usr/bin/env bash
# Real-engine acceptance for an OpenAI-compatible endpoint (SPEC §06 R rows).
# Usage: Scripts/acceptance.sh <endpoint> <model> [chat|responses]
# The API key is read at run time from the Keychain item the app writes (Settings › Engines › OpenAI Compatible › API key):
#   service com.transframe.v2.dev.credentials (Debug) or com.transframe.v2.credentials, account engine.openai-compatible.apiKey.
# It is passed only in this process's environment and is never printed or stored. Loopback endpoints need no key.
set -euo pipefail
cd "$(dirname "$0")/.."
endpoint="${1:?endpoint, e.g. https://api.openai.com/v1}"; model="${2:?model}"; api="${3:-chat}"
key=""
for service in com.transframe.v2.dev.credentials com.transframe.v2.credentials; do
  key="$(security find-generic-password -s "$service" -a engine.openai-compatible.apiKey -w 2>/dev/null || true)"
  [[ -n "$key" ]] && break
done
if [[ -z "$key" && ! "$endpoint" =~ ^https?://(127\.0\.0\.1|localhost) ]]; then
  echo "No key in the Keychain. Open TransFrame 2 › Settings › Engines › OpenAI Compatible, paste the key and press Save."; exit 1
fi
mkdir -p Docs/walkthroughs/records
log="Docs/walkthroughs/records/$(date +%Y-%m-%d)-acceptance-openai-compatible.md"
cd Packages/TransFrameKit
result="$(TF_ACCEPT_ENDPOINT="$endpoint" TF_ACCEPT_MODEL="$model" TF_ACCEPT_API="$api" TF_ACCEPT_KEY="$key" \
  swift test --filter RealEngineAcceptance 2>&1 | grep -E '✔|✘|TF_ACCEPT|Test run' || true)"
cd ../..
host="$(sed -E 's#^https?://([^/]+).*#\1#' <<<"$endpoint")"
{ echo "# Real-engine acceptance: OpenAI-compatible"; echo; echo "- Date: $(date '+%Y-%m-%d %H:%M')"; echo "- macOS: $(sw_vers -productVersion)"
  echo "- Host: $host · model: $model · API: $api"; echo; echo '```'; echo "$result"; echo '```'; } > "$log"
echo "$result"; echo "record: $log"
grep -q '✘' <<<"$result" && exit 1 || exit 0
