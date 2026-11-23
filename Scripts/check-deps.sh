#!/usr/bin/env bash
# Dependency direction gate (SPEC §01 §2.2). Usage: check-deps.sh [--self-test]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--self-test" ]]; then
  # A deliberately violating copy must fail: Domain importing AppKit and a forbidden singleton.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/Scripts" "$tmp/Packages"
  cp "$ROOT/Scripts/check_deps.py" "$ROOT/Scripts/unsafe-allowlist.txt" "$tmp/Scripts/"
  rsync -a --exclude .build --exclude .swiftpm "$ROOT/Packages/TransFrameKit" "$tmp/Packages/"
  printf 'import AppKit\nenum Bad { static let shared = 1 }\n' > "$tmp/Packages/TransFrameKit/Sources/TFDomain/Violation.swift"
  if TF_ROOT="$tmp" python3 "$tmp/Scripts/check_deps.py" > "$tmp/out.txt"; then
    echo "self-test FAILED: violation was not detected"; cat "$tmp/out.txt"; exit 1
  fi
  grep -q "import AppKit not allowed in TFDomain" "$tmp/out.txt" && grep -q "static let shared" "$tmp/out.txt" \
    || { echo "self-test FAILED: unexpected output"; cat "$tmp/out.txt"; exit 1; }
  echo "check-deps self-test passed"
  exit 0
fi

python3 "$ROOT/Scripts/check_deps.py"
# App/ may use singletons, but macOS 26 availability is confined to four modules (ADR-0007).
if grep -rEn '[#@]available\(\s*macOS\s+2[6-9]' "$ROOT/App" --include='*.swift' >/dev/null 2>&1; then
  echo "[macos26] App/ must not contain macOS 26 availability checks"; exit 1
fi
