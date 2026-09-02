#!/usr/bin/env bash
# Прогон всех тестов домена packages/core (эквивалент `dart test` без pub.dev).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/packages/core"
DART="$ROOT/.tools/dart-sdk/bin/dart"
[ -x "$DART" ] || DART="dart"

cd "$CORE"
FAILED=0
for t in test/*_test.dart; do
  echo "=== $(basename "$t") ==="
  "$DART" "$t" || { echo "FAILED: $t"; FAILED=1; }
done
if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "SOME TESTS FAILED"
  exit 1
fi
