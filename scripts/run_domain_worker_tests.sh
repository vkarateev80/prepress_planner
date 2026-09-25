#!/usr/bin/env bash
# Прогон тестов domain-worker (эквивалент `dart test` без pub.dev).
# Каждый test/*_test.dart — исполняемый скрипт с void main(); код выхода 0 = успех.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="$ROOT/services/domain-worker"
DART="$ROOT/.tools/dart-sdk/bin/dart"
[ -x "$DART" ] || DART="dart"

cd "$WORKER"

# Зависимость только path: packages/core — идёт офлайн, сеть/pub.dev не нужны.
"$DART" pub get --offline

echo "=== dart analyze ==="
"$DART" analyze lib bin test tool

FAILED=0
for t in test/*_test.dart; do
  echo "=== $(basename "$t") ==="
  "$DART" "$t" || { echo "FAILED: $t"; FAILED=1; }
done

echo "=== эталонные числа (домен + HTTP) ==="
"$DART" tool/verify_reference.dart --http || { echo "FAILED: эталон не сошёлся"; FAILED=1; }

echo "=== расчётный путь: импорт → лечение → массив → раскрой → ТЭО ==="
"$DART" tool/verify_calculation_path.dart || {
  echo "FAILED: расчётный путь не подтверждён"; FAILED=1; }

echo "=== отчёты: PDF (кириллица) / XLSX / DXF ==="
"$DART" tool/verify_reports.dart || { echo "FAILED: отчёты не подтверждены"; FAILED=1; }

if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASS (domain-worker)"
else
  echo "SOME TESTS FAILED (domain-worker)"
  exit 1
fi
