#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
FAIL=0
for t in "$DIR"/*_test.sh; do
  echo "== $(basename "$t") =="
  bash "$t" || FAIL=1
done
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
