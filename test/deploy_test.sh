#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"; . "$ROOT/deploy.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

export PIPELINE_DIR="$TMP/olympus"; mkdir -p "$PIPELINE_DIR/state"
export TARGET_REPO="$TMP/repo"; mkdir -p "$TARGET_REPO"

# 1) DEPLOY_CMD(env) 우선 — TARGET_REPO에서 실행됨
( export DEPLOY_CMD="touch deployed_by_env"; deploy_project >/dev/null; echo $? > "$TMP/rc1" )
assert_eq "0" "$(cat "$TMP/rc1")" "DEPLOY_CMD 실행 성공 반환 0"
[ -f "$TARGET_REPO/deployed_by_env" ] && pass "DEPLOY_CMD가 TARGET_REPO에서 실행됨" || fail "DEPLOY_CMD 미실행"

# 2) DEPLOY_CMD 없고 state/deploy.md에 명령 → 그걸 실행
printf '<!-- 배포 규약 -->\ntouch deployed_by_state\n' > "$PIPELINE_DIR/state/deploy.md"
( unset DEPLOY_CMD; deploy_project >/dev/null; echo $? > "$TMP/rc2" )
assert_eq "0" "$(cat "$TMP/rc2")" "state 배포명령 실행 성공"
[ -f "$TARGET_REPO/deployed_by_state" ] && pass "state/deploy.md 명령 실행됨" || fail "state 명령 미실행"

# 3) 규약 전무(빈 deploy.md, DEPLOY_CMD 없음) → 10 반환(배포 안 함)
printf '<!-- 초기 상태: 비어 있음 -->\n' > "$PIPELINE_DIR/state/deploy.md"
( unset DEPLOY_CMD; deploy_project >/dev/null 2>&1; echo $? > "$TMP/rc3" )
assert_eq "10" "$(cat "$TMP/rc3")" "규약 없으면 10 반환(사용자에게 물어봄 신호)"

# 4) deploy.md 파일 자체가 없어도 10
rm -f "$PIPELINE_DIR/state/deploy.md"
( unset DEPLOY_CMD; deploy_project >/dev/null 2>&1; echo $? > "$TMP/rc4" )
assert_eq "10" "$(cat "$TMP/rc4")" "deploy.md 없어도 10"

[ "${TESTS_FAIL:-0}" -eq 0 ]
