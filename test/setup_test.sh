#!/usr/bin/env bash
# setup.sh — 로컬 세팅 마이그레이션: 버전 비교 적용·멱등·마커 관리 검증
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$TMP/olympus"
export HOME="$TMP/home"          # 실제 셸 rc를 건드리지 않게 격리
export SHELL="/bin/zsh"
mkdir -p "$PIPELINE_DIR" "$HOME"
cp "$ROOT/setup.sh" "$PIPELINE_DIR/setup.sh"

MARKER="$PIPELINE_DIR/state/setup.version"
RC="$HOME/.zshrc"

# 1) 최초 적용 — 전 단계 실행, 마커 = SETUP_VERSION, alias 추가
. "$PIPELINE_DIR/setup.sh"
setup_apply >/dev/null
assert_eq "$SETUP_VERSION" "$(cat "$MARKER")" "마커 = SETUP_VERSION"
assert_eq "1" "$(grep -c "alias olympus=" "$RC")" "alias olympus 추가"

# 2) 멱등 — 재적용해도 중복 없음·마커 유지
setup_apply >/dev/null
assert_eq "1" "$(grep -c "alias olympus=" "$RC")" "재적용해도 alias 중복 없음"
assert_eq "$SETUP_VERSION" "$(cat "$MARKER")" "재적용해도 마커 유지"

# 3) 이미 alias가 있는 기기(수동 등록) — 덧붙이지 않고 마커만 갱신
rm -f "$MARKER"; echo "alias olympus='bash /elsewhere/start.command'" > "$RC"
setup_apply >/dev/null
assert_eq "1" "$(grep -c "alias olympus=" "$RC")" "기존 alias 존중(중복 추가 없음)"
assert_eq "$SETUP_VERSION" "$(cat "$MARKER")" "기존 alias 기기도 마커 갱신"

# 4) 손상된 마커(숫자 아님) → 0으로 간주하고 처음부터(멱등이라 안전)
echo "abc" > "$MARKER"; : > "$RC"
setup_apply >/dev/null
assert_eq "$SETUP_VERSION" "$(cat "$MARKER")" "손상 마커 복구"
assert_eq "1" "$(grep -c "alias olympus=" "$RC")" "복구 후 단계 재적용"

# 5) 최신 상태면 no-op (rc를 지워도 다시 안 만듦 — 버전이 곧 계약)
: > "$RC"
setup_apply >/dev/null
assert_eq "0" "$(grep -c "alias olympus=" "$RC")" "최신 버전이면 no-op"

# 6) CLI 직접 실행도 동작
rm -f "$MARKER"
bash "$PIPELINE_DIR/setup.sh" >/dev/null
assert_eq "$SETUP_VERSION" "$(cat "$MARKER")" "bash setup.sh 직접 실행"

echo; echo "setup: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
