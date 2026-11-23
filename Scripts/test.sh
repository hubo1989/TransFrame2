#!/usr/bin/env bash
# Test runner. Usage: test.sh [package|app|smoke|all]
#   package  swift test for every package target (U, C, I) + 90% line coverage for TFDomain and TFPipelines
#   app      xcodebuild test (UI target) + launch smoke
#   smoke    build Debug and launch with TF_SMOKE_TEST=1, expecting the menu-ready marker
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/TransFrameKit"
MODE="${1:-all}"
mkdir -p "$ROOT/build"

package_tests() {
  (cd "$PKG" && swift test --enable-code-coverage --parallel 2>&1 | tee "$ROOT/build/package-tests.log" | grep -E "✘|error:|Test run|passed after|failed after" | tail -40)
  grep -q "✘" "$ROOT/build/package-tests.log" && { echo "package tests failed"; exit 1; }
  grep -qE "error: (fatalError|Build failed)" "$ROOT/build/package-tests.log" && { echo "package build failed"; exit 1; }
  coverage
}

coverage() {
  # Each test target is its own bundle with swiftbuild, so merge every profile and report against all bundles.
  local dir bins=() merged="$ROOT/build/coverage.profdata"
  dir="$(dirname "$(find "$PKG/.build" -name 'default.profdata' -path '*codecov*' | head -1)")"
  if [[ -z "$dir" || "$dir" == "." ]]; then echo "coverage data not found"; return 1; fi
  xcrun llvm-profdata merge -sparse "$dir"/*.profraw -o "$merged"
  while IFS= read -r bin; do bins+=(-object "$bin"); done < <(find "$PKG/.build" -path '*.xctest/Contents/MacOS/*' -type f -perm -111)
  [[ ${#bins[@]} -gt 0 ]] || { echo "coverage binaries not found"; return 1; }
  xcrun llvm-cov export -summary-only -instr-profile "$merged" "${bins[@]:1}" > "$ROOT/build/coverage.json"
  python3 - "$ROOT/build/coverage.json" "$ROOT/build/coverage.txt" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
totals, rows, seen = {}, [], set()
for f in data["data"][0]["files"]:
    name = f["filename"]
    if name in seen:
        continue
    seen.add(name)
    for module in ("TFDomain", "TFPipelines"):
        if f"/Sources/{module}/" in name:
            lines = f["summary"]["lines"]
            t = totals.setdefault(module, [0, 0])
            t[0] += lines["count"]; t[1] += lines["covered"]
            rows.append(f"{lines['percent']:6.1f}%  {name.split('/Sources/')[1]}")
open(sys.argv[2], "w").write("\n".join(sorted(rows)) + "\n")
failed = False
for module, (total, covered) in sorted(totals.items()):
    pct = 100.0 * covered / total if total else 100.0
    print(f"coverage {module}: {pct:.1f}% lines ({covered}/{total})")
    failed |= pct < 90.0
sys.exit(1 if failed else 0)
PY
}

smoke() {
  local app
  app="$("$ROOT/Scripts/build.sh" Debug -quiet | tail -1)"
  local out
  out="$(TF_SMOKE_TEST=1 timeout 60 "$app/Contents/MacOS/TransFrame 2" 2>/dev/null || true)"
  if grep -q "TF2_MENU_READY" <<<"$out"; then echo "launch smoke passed"; else echo "launch smoke FAILED"; exit 1; fi
}

app_tests() {
  xcodebuild -project "$ROOT/TransFrame2.xcodeproj" -scheme TransFrame2 -configuration Debug \
    -derivedDataPath "$ROOT/build/DerivedData" SYMROOT="$ROOT/build/Products" OBJROOT="$ROOT/build/Intermediates" \
    -skipPackagePluginValidation -quiet test
  smoke
}

case "$MODE" in
  package) package_tests ;;
  app) app_tests ;;
  smoke) smoke ;;
  all) package_tests; smoke ;;
  *) echo "usage: test.sh [package|app|smoke|all]"; exit 2 ;;
esac
