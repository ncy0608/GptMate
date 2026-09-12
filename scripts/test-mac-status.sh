#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gptmate-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/TaskActivity.swift" \
  "$PROJECT_DIR/Sources/RateLimitSnapshot.swift" \
  "$PROJECT_DIR/Sources/SessionLogInspector.swift" \
  "$PROJECT_DIR/Tests/main.swift" -o "$TEST_DIR/mac-status-tests"
"$TEST_DIR/mac-status-tests"
