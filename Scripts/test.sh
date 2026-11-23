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
  local profdata binary
  profdata="$(find "$PKG/.build" -name 'default.profdata' -path '*codecov*' | head -1)"
  binary="$(find "$PKG/.build" -name 'TransFrameKitPackageTests' -type f -perm -111 | head -1)"
  [[ -z "$binary" ]] && binary="$(find "$PKG/.build" -path '*TransFrameKitPackageTests.xctest/Contents/MacOS/*' -type f | head -1)"
  if [[ -z "$profdata" || -z "$binary" ]]; then echo "coverage data not found"; return 0; fi
  xcrun llvm-cov report "$binary" -instr-profile "$profdata" -ignore-filename-regex='(\.build|Tests|TestSupport)' \
    > "$ROOT/build/coverage.txt"
  python3 - "$ROOT/build/coverage.txt" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
totals = {}
for line in lines:
    m = re.match(r"(\S+/Sources/(TFDomain|TFPipelines)/\S+)\s+.*?(\d+)\s+(\d+)\s+[\d.]+%\s*$", line)
    parts = line.split()
    if "/Sources/TFDomain/" in line or "/Sources/TFPipelines/" in line:
        module = "TFDomain" if "/Sources/TFDomain/" in line else "TFPipelines"
        # llvm-cov columns: Regions Missed Cover Functions Missed Cover Lines Missed Cover [Branches...]
        nums = [p for p in parts[1:]]
        try:
            lines_total, lines_missed = int(nums[6]), int(nums[7])
        except (ValueError, IndexError):
            continue
        t = totals.setdefault(module, [0, 0])
        t[0] += lines_total; t[1] += lines_missed
failed = False
for module, (total, missed) in sorted(totals.items()):
    pct = 100.0 * (total - missed) / total if total else 100.0
    print(f"coverage {module}: {pct:.1f}% lines ({total - missed}/{total})")
    if pct < 90.0:
        failed = True
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
