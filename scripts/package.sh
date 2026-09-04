#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$PROJECT_DIR/scripts/build.sh"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
for arch in arm64 x86_64; do
  case "$arch" in
    arm64) edition="AppleSilicon-arm64" ;;
    x86_64) edition="Intel-x86_64" ;;
  esac
  ARCHIVE="$PROJECT_DIR/dist/GptMate-v${VERSION}-macOS-${edition}.zip"
  ditto -c -k --keepParent "$PROJECT_DIR/dist/$arch/GptMate.app" "$ARCHIVE"
  (cd "$PROJECT_DIR/dist" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
  printf 'Packaged: %s\n' "$ARCHIVE"
done
