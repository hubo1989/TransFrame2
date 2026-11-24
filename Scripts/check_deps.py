#!/usr/bin/env python3
"""Dependency direction gate (SPEC §01 §2.2). Exit code 1 on any violation.

Checks: 1) target edges against the whitelist, 2) imports per module,
3) forbidden symbols outside App/, 4) macOS 26 availability only in four modules.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.environ.get("TF_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "Packages", "TransFrameKit")
SOURCES = os.path.join(PKG, "Sources")
ALLOWLIST = os.path.join(ROOT, "Scripts", "unsafe-allowlist.txt")

FEATURES = [
    "CaptureFeature", "EditorFeature", "PinFeature", "TextTranslationFeature", "HistoryFeature",
    "SettingsFeature", "OnboardingFeature", "MenuBarFeature", "AboutFeature", "ColorFeature",
]
INFRA = [
    "TFCaptureInfra", "TFRecognitionInfra", "TFTranslationInfra", "TFAIInfra", "TFRenderInfra",
    "TFPersistenceInfra", "TFSystemInfra", "TFUploadInfra",
]
UI_BASE = {"TFDomain", "TFDesignSystem", "TFLocalization", "TFWorkspaceUI"}

# §01 §2.1 — allowed module dependencies (exhaustive).
EDGES = {
    "TFDomain": set(),
    "TFPipelines": {"TFDomain"},
    "TFNetworkInfra": {"TFDomain"},
    "TFLocalization": set(),
    "TFDesignSystem": {"TFLocalization"},
    "TFWorkspaceUI": {"TFDomain", "TFDesignSystem", "TFLocalization"},
    "TFDomainTestSupport": {"TFDomain"},
}
EDGES.update({m: {"TFDomain", "TFNetworkInfra"} for m in INFRA})
EDGES["TFSystemInfra"] |= {"Sparkle", "PermissionFlow"}
EDGES.update({f: set(UI_BASE) for f in FEATURES})

UI_SYS = {"SwiftUI", "AppKit", "Foundation", "Observation", "CoreGraphics"}
IMPORTS = {
    "TFDomain": {"Foundation", "CoreGraphics", "Observation"},
    "TFPipelines": {"Foundation", "CoreGraphics", "CryptoKit", "os"},
    "TFNetworkInfra": {"Foundation", "os"},
    "TFCaptureInfra": {"Foundation", "ScreenCaptureKit", "CoreGraphics", "AppKit", "os"},
    "TFRecognitionInfra": {"Foundation", "Vision", "ImageIO", "NaturalLanguage", "CoreGraphics", "CoreImage", "os"},
    "TFTranslationInfra": {"Foundation", "Translation", "NaturalLanguage", "CryptoKit", "os"},
    "TFAIInfra": {"Foundation", "FoundationModels", "NaturalLanguage", "os"},
    "TFRenderInfra": {"Foundation", "CoreGraphics", "CoreText", "CoreImage", "ImageIO", "AppKit", "UniformTypeIdentifiers", "os"},
    "TFPersistenceInfra": {"Foundation", "SwiftData", "Security", "Observation", "os"},
    "TFSystemInfra": {"Foundation", "Carbon", "ApplicationServices", "AppKit", "LocalAuthentication", "CoreGraphics", "os", "Sparkle", "PermissionFlow"},
    "TFUploadInfra": {"Foundation", "CryptoKit", "os"},
    "TFLocalization": {"Foundation", "SwiftUI", "Observation"},
    "TFDesignSystem": UI_SYS,
    "TFWorkspaceUI": UI_SYS | {"QuartzCore"},
    "TFDomainTestSupport": {"Foundation", "CoreGraphics", "Observation"},
}
IMPORTS.update({f: UI_SYS | {"UniformTypeIdentifiers"} for f in FEATURES})

AVAILABILITY_26 = {"TFDesignSystem", "TFTranslationInfra", "TFRecognitionInfra", "TFAIInfra"}
FORBIDDEN = [
    (re.compile(r"\bstatic\s+let\s+shared\b"), "static let shared"),
    (re.compile(r"\bUserDefaults\.standard\b"), "UserDefaults.standard"),
    (re.compile(r"\bDispatchQueue\b"), "DispatchQueue"),
    (re.compile(r"\bNotificationCenter\.default\.post\b"), "NotificationCenter.default.post"),
    (re.compile(r"(?<![\w.])print\("), "print("),
    (re.compile(r"\bTask\.detached\b"), "Task.detached"),
    (re.compile(r"\bDispatchSemaphore\b"), "DispatchSemaphore"),
]
UNSAFE = re.compile(r"@unchecked\s+Sendable|nonisolated\(unsafe\)")
PASTEBOARD = re.compile(r"\bNSPasteboard\b")


def dump_package():
    out = subprocess.run(
        ["swift", "package", "dump-package"], cwd=PKG, capture_output=True, text=True, check=True
    ).stdout
    return json.loads(out)


def target_deps(target):
    deps = set()
    for d in target.get("dependencies", []):
        for kind in ("byName", "target", "product"):
            if kind in d:
                deps.add(d[kind][0])
    return deps


def load_allowlist():
    entries = []
    if os.path.exists(ALLOWLIST):
        with open(ALLOWLIST, encoding="utf-8") as f:
            for line in f:
                body = line.split("#", 1)
                if len(body) < 2 and line.strip():
                    entries.append(("__missing_reason__", line.strip()))
                    continue
                path = body[0].strip()
                if path:
                    entries.append((path, body[1].strip()))
    return entries


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def strip_strings(text):
    return re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)


def main():
    errors = []
    package = dump_package()
    targets = {t["name"]: t for t in package["targets"]}

    for name, target in targets.items():
        if target["type"] == "test":
            continue
        if name not in EDGES:
            errors.append(f"[edges] unknown target not in whitelist: {name}")
            continue
        extra = target_deps(target) - EDGES[name]
        for dep in sorted(extra):
            errors.append(f"[edges] {name} -> {dep} is not allowed")

    allow = load_allowlist()
    for path, reason in allow:
        if path == "__missing_reason__":
            errors.append(f"[unsafe] allowlist entry without reason: {reason}")

    for module in sorted(os.listdir(SOURCES)):
        mdir = os.path.join(SOURCES, module)
        if not os.path.isdir(mdir):
            continue
        allowed_imports = IMPORTS.get(module, set()) | EDGES.get(module, set())
        for base, _, files in os.walk(mdir):
            for fname in files:
                if not fname.endswith(".swift"):
                    continue
                path = os.path.join(base, fname)
                rel = os.path.relpath(path, ROOT)
                with open(path, encoding="utf-8") as f:
                    raw = f.read()
                code = strip_strings(strip_comments(raw))
                for m in re.finditer(r"^\s*(?:@[\w()]+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|typealias)\s+)?([\w]+)", code, re.M):
                    if m.group(1) not in allowed_imports:
                        errors.append(f"[imports] {rel}: import {m.group(1)} not allowed in {module}")
                for regex, label in FORBIDDEN:
                    if regex.search(code):
                        errors.append(f"[symbols] {rel}: forbidden '{label}' outside App/")
                for lineno, line in enumerate(code.splitlines(), 1):
                    if UNSAFE.search(line) and not any(rel.startswith(p.rstrip("*")) if p.endswith("*") else rel == p for p, _ in allow):
                        errors.append(f"[unsafe] {rel}:{lineno}: unregistered unsafe concurrency annotation")
                if re.search(r"[#@]available\(\s*macOS\s+2[6-9]", code) and module not in AVAILABILITY_26:
                    errors.append(f"[macos26] {rel}: macOS 26 availability outside {sorted(AVAILABILITY_26)}")
                if PASTEBOARD.search(code) and module != "TFSystemInfra":
                    errors.append(f"[isolation] {rel}: system pasteboard outside TFSystemInfra")

    for e in errors:
        print(e)
    print(f"check-deps: {len(targets)} targets, {len(errors)} violations")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
