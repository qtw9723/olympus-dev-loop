#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$ROOT" TARGET_REPO="$TMP/repo" STATE_DIR="$TMP/state" SPEC_DIR="$ROOT/spec"
mkdir -p "$STATE_DIR"
. "$ROOT/prompts.sh"

P="$(OLYMPUS_MODE=lite metis_prompt M0)"
assert_contains "$P" "라이트 모드" "lite → 라이트 지시 포함"
P="$(OLYMPUS_MODE=auto metis_prompt M0)"
assert_contains "$P" "\"mode\"" "auto → 판정·handoff 기록 지시 포함"
P="$(OLYMPUS_MODE=full metis_prompt M0)"
assert_not_contains "$P" "라이트 모드" "full → 라이트 지시 없음"
P="$(metis_prompt M0)"
assert_not_contains "$P" "라이트 모드" "미지정(기본 full) → 라이트 지시 없음"

echo; echo "prompts_lite: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
