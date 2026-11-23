#!/usr/bin/env bash
# Builds the app. Usage: build.sh [Debug|Release] [extra xcodebuild args...]
# SYMROOT/OBJROOT are explicit so nothing lands in Xcode's shared products dir (SPEC §01 §11).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Debug}"; shift || true
BUILD="$ROOT/build"
xcodebuild -project "$ROOT/TransFrame2.xcodeproj" -scheme TransFrame2 -configuration "$CONFIG" \
  -derivedDataPath "$BUILD/DerivedData" SYMROOT="$BUILD/Products" OBJROOT="$BUILD/Intermediates" \
  -skipPackagePluginValidation "$@" build
echo "$BUILD/Products/$CONFIG/TransFrame 2.app"
