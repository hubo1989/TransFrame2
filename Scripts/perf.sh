#!/usr/bin/env bash
# Performance suite (SPEC §04 §5.4). Usage: Scripts/perf.sh pipeline
# Runs the package perf tests in release mode, writes PerfReports/<date>-<commit>.json plus a readable summary,
# and compares with PerfBaselines/m4pro.json when present. Screen-bound metrics (P-*) need the Debug perf driver on a
# local, authorized machine and are not part of this suite.
set -euo pipefail
cd "$(dirname "$0")/.."
suite="${1:-pipeline}"
[[ "$suite" == "pipeline" ]] || { echo "unknown suite: $suite (only 'pipeline' runs headless)"; exit 2; }
out="$(mktemp -d)"
commit="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
stamp="$(date +%Y-%m-%d)"
mkdir -p PerfReports
( cd Packages/TransFrameKit && TF_PERF_OUT="$out" swift test -c release --filter 'Perf' >/dev/null )
python3 - "$out" "PerfReports/$stamp-$commit.json" PerfBaselines/m4pro.json <<'PY'
import json, math, os, platform, subprocess, sys
src, dst, baseline_path = sys.argv[1:4]
budgets = {"R-04": 150, "R-05": 50, "R-06": 200, "R-09": 20, "O-02": 100, "O-03": 100, "O-04": 300}
def pct(v, p):
    s = sorted(v); return s[max(math.ceil(p / 100 * len(s)), 1) - 1]
baseline = json.load(open(baseline_path)) if os.path.exists(baseline_path) else {}
report = {"machine": platform.machine(), "os": platform.mac_ver()[0], "metrics": {}}
for name in sorted(os.listdir(src)):
    metric = name[:-5]
    samples = json.load(open(os.path.join(src, name)))
    entry = {"n": len(samples), "min": min(samples), "max": max(samples), "p50": pct(samples, 50), "p95": pct(samples, 95), "budget_p95": budgets.get(metric)}
    entry["verdict"] = "insufficient samples" if len(samples) < 50 else ("pass" if entry["budget_p95"] is None or entry["p95"] <= entry["budget_p95"] else "FAIL")
    if metric in baseline.get("metrics", {}):
        entry["baseline_p95"] = baseline["metrics"][metric]["p95"]
    report["metrics"][metric] = entry
json.dump(report, open(dst, "w"), indent=2)
print(f"{'metric':8} {'n':>4} {'p50 ms':>9} {'p95 ms':>9} {'budget':>8}  verdict")
for k, e in report["metrics"].items():
    print(f"{k:8} {e['n']:>4} {e['p50']:>9.2f} {e['p95']:>9.2f} {str(e['budget_p95'] or '-'):>8}  {e['verdict']}")
print(f"report: {dst}")
PY
