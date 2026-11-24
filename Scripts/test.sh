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
  local log="$ROOT/build/package-tests.log" status=0 parallel="--parallel"
  # CI runners have three cores: run serially there, so a test that blocks a thread cannot starve the rest and a hang
  # names its test (the last one started).
  [[ -n "${CI:-}" ]] && parallel="--no-parallel"
  # Watchdog: a hung test must not eat the CI job. On timeout the tests that started but never finished are listed.
  # script(1) gives the run a pseudo-terminal, so output reaches the log line by line (a plain file is block-buffered and
  # loses the tail when the watchdog fires); it exits with the command's status.
  (cd "$PKG" && perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or die "exec: $!"' "${TF_TEST_TIMEOUT:-1500}" \
    script -q "$log" swift test --enable-code-coverage "$parallel") > /dev/null 2>&1 || status=$?
  grep -E "✘|error:|Test run|passed after|failed after" "$log" | tail -40
  if [[ $status -eq 142 ]]; then
    echo "--- package tests timed out after ${TF_TEST_TIMEOUT:-1500} s; started but never finished: ---"
    python3 - "$log" <<'PY'
import re, sys
text = re.sub(r"\x1b\[[0-9;]*m", "", open(sys.argv[1], errors="replace").read())
clean = lambda name: re.sub(r" with \d+ test cases?$", "", name)
started = {clean(n) for n in re.findall(r"◇ (?:Test|Suite) (.+?) started\.", text)}
finished = {clean(n) for n in re.findall(r"[✔✘] (?:Test|Suite) (.+?) (?:passed|failed)", text)}
for name in sorted(started - finished):
    print("  " + name)
PY
    exit 1
  fi
  if grep -q "✘" "$log"; then
    # The summary above keeps only the tail; list every failing test and its expectation.
    echo "--- failures ---"
    grep -E "recorded an issue|↳" "$log" | grep -v -E "Testing Library|Target Platform" | head -120
    echo "package tests failed"; exit 1
  fi
  grep -qE "error: (fatalError|Build failed)" "$log" && { echo "package build failed"; exit 1; }
  [[ $status -eq 0 ]] || { echo "swift test exited with $status"; tail -20 "$log"; exit 1; }
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
  # perl alarm instead of coreutils `timeout`, which macOS runners do not ship.
  out="$(TF_SMOKE_TEST=1 perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or die "exec: $!"' 60 "$app/Contents/MacOS/TransFrame 2" 2>&1; echo "exit=$?")"
  if grep -q "TF2_MENU_READY" <<<"$out"; then echo "launch smoke passed"; return 0; fi
  echo "launch smoke FAILED"
  tail -40 <<<"$out"
  # Crash report, if any, for diagnosis on CI.
  report="$(ls -t ~/Library/Logs/DiagnosticReports/TransFrame* 2>/dev/null | head -1)"
  [[ -n "$report" ]] && head -80 "$report"
  exit 1
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
