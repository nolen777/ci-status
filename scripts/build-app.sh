#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/CIStatus.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-.build/module-cache}" swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/CIStatus" "$MACOS_DIR/CIStatus"
cp "Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "Packaging/CIStatus.icns" "$RESOURCES_DIR/CIStatus.icns"

echo "Built $APP_DIR"
