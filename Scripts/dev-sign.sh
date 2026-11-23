#!/usr/bin/env bash
# Re-signs the Debug app with a stable Apple Development identity so macOS privacy grants (Screen Recording, Accessibility)
# survive rebuilds. Usage: Scripts/dev-sign.sh [identity-sha1]   (default: first "Apple Development" identity)
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/Products/Debug/TransFrame 2.app"
identity="${1:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
[[ -n "$identity" ]] || { echo "no Apple Development identity"; exit 1; }
codesign --force --deep --timestamp=none --options runtime --entitlements App/TransFrame2.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict "$app" && echo "signed: $app"
