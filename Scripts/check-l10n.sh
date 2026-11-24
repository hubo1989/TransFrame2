#!/usr/bin/env bash
# Localization completeness gate (SPEC §05 §7). Usage: check-l10n.sh [--self-test]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/Scripts" "$tmp/Packages/TransFrameKit/Sources/TFLocalization/Resources" "$tmp/App"
  cp "$ROOT/Scripts/l10n.py" "$tmp/Scripts/"
  cat > "$tmp/Packages/TransFrameKit/Sources/TFLocalization/Resources/Localizable.xcstrings" <<'JSON'
{"sourceLanguage":"en","version":"1.0","strings":{"demo.key":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Demo"}}}}}}
JSON
  printf 'let x = L10nKey.demoKey\n' > "$tmp/App/Use.swift"
  if python3 "$tmp/Scripts/l10n.py" check > "$tmp/out.txt"; then echo "self-test FAILED"; exit 1; fi
  grep -q "missing translation: demo.key \[ja\]" "$tmp/out.txt" || { cat "$tmp/out.txt"; exit 1; }
  echo "check-l10n self-test passed"; exit 0
fi
python3 "$ROOT/Scripts/l10n.py" check
