#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
mkdir -p "$BUILD_DIR/module-cache"

for arch in arm64 x86_64; do
  APP_DIR="$PROJECT_DIR/dist/$arch/GptMate.app"
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  xcrun swiftc -O -target "${arch}-apple-macosx13.0" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$PROJECT_DIR"/Sources/*.swift -o "$BUILD_DIR/gptmate-$arch"
  cp "$BUILD_DIR/gptmate-$arch" "$APP_DIR/Contents/MacOS/gptmate"
  cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
  cp "$PROJECT_DIR/Resources/GptMateIcon.icns" "$APP_DIR/Contents/Resources/"
  plutil -lint "$APP_DIR/Contents/Info.plist"
  codesign --force --sign - "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
  printf 'Built: %s\n' "$APP_DIR"
done
