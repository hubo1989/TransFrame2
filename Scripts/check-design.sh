#!/usr/bin/env bash
# Design-token gate (SPEC §05 §9): UI modules outside TFDesignSystem must use tokens.
# Usage: check-design.sh [--self-test]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

run() {
python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
pkg = os.path.join(root, "Packages", "TransFrameKit", "Sources")
allow_file = os.path.join(root, "Scripts", "design-allowlist.txt")
allow = []
if os.path.exists(allow_file):
    for line in open(allow_file, encoding="utf-8"):
        body = line.split("#", 1)[0].strip()
        if body:
            allow.append(body)
dirs = [os.path.join(root, "App")]
if os.path.isdir(pkg):
    dirs += [os.path.join(pkg, d) for d in os.listdir(pkg) if d.endswith("Feature") or d == "TFWorkspaceUI"]
rules = [
    (r"cornerRadius:\s*\d", "literal corner radius"),
    (r"\.cornerRadius\(", "deprecated cornerRadius modifier"),
    (r"\.foregroundColor\(", "deprecated foregroundColor"),
    (r"(Font|\.)system\(size:\s*\d", "literal font size"),
    (r"NSFont\.(systemFont|monospacedSystemFont|boldSystemFont)\(ofSize:\s*\d", "literal font size"),
    (r"(Color|NSColor)\((red|calibratedRed|deviceRed):\s*[\d.]+", "literal color"),
    (r"\.(easeIn|easeOut|easeInOut|linear|spring)\(duration:\s*[\d.]+", "literal animation duration"),
    (r"\.glassEffect\(|GlassEffectContainer|\.buttonStyle\(\.glass", "direct glass API"),
    (r"(ultraThin|thin|regular|thick|ultraThick)Material\b|NSVisualEffectView", "direct material API"),
    (r"\.animation\(\s*[^,()]*(\([^()]*\))?\s*\)", "implicit animation without value"),
    (r"\b(Button|Text|Label|Toggle|Picker)\(\s*\"\"", "empty title"),
]
errors = []
for d in dirs:
    for base, _, files in os.walk(d):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root)
            if any(rel == a or (a.endswith("*") and rel.startswith(a[:-1])) for a in allow):
                continue
            for n, line in enumerate(open(path, encoding="utf-8"), 1):
                code = line.split("//", 1)[0]
                for pattern, label in rules:
                    if re.search(pattern, code):
                        errors.append(f"{rel}:{n}: {label}: {line.strip()[:90]}")
for e in errors:
    print(e)
print(f"check-design: {len(errors)} violations")
sys.exit(1 if errors else 0)
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/App" "$tmp/Scripts"
  printf 'let v = Text("x").font(.system(size: 13)).foregroundColor(.red)\n' > "$tmp/App/Bad.swift"
  if run "$tmp" > "$tmp/out.txt"; then echo "self-test FAILED"; exit 1; fi
  grep -q "literal font size" "$tmp/out.txt" && grep -q "deprecated foregroundColor" "$tmp/out.txt" || { cat "$tmp/out.txt"; exit 1; }
  echo "check-design self-test passed"; exit 0
fi
run "$ROOT"
