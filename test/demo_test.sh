#!/usr/bin/env bash
# 오프라인 데모를 통째로 실행해 run.sh 루프·심판 적발·사람 개입 후 재개·머지를 회귀 검증한다.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
OUT="$(bash "$ROOT/demo/run-demo.sh" 2>&1)"; RC=$?
assert_eq "0" "$RC" "demo/run-demo.sh 종료코드"
assert_contains "$OUT" "데모 통과" "데모 전 항목 통과"
assert_contains "$OUT" "재개 — 기존 작업 브랜치" "재개 시 작업 브랜치 이어받기"

echo "demo: run=$TESTS_RUN fail=$TESTS_FAIL"
[ "${TESTS_FAIL:-0}" -eq 0 ]
