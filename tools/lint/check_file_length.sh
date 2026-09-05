#!/usr/bin/env bash
# CTO Rule (blueprint §7.2, §24.3): no source file over 800 lines.
# Toad's ~2,400-line bt_app_hf.c is the failure mode this prevents.
set -euo pipefail

MAX=800
fail=0

while IFS= read -r -d '' f; do
  lines=$(wc -l < "$f" | tr -d ' ')
  if [ "$lines" -gt "$MAX" ]; then
    echo "FAIL: $f has $lines lines (max $MAX)"
    fail=1
  fi
done < <(git ls-files -z -- \
  '*.c' '*.h' '*.cpp' '*.hpp' \
  '*.dart' '*.ts' '*.tsx' '*.py' '*.kt' '*.swift')

if [ "$fail" -eq 0 ]; then
  echo "OK: no file exceeds $MAX lines"
fi
exit $fail
