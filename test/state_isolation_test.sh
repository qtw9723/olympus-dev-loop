#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$TMP/olympus"; mkdir -p "$PIPELINE_DIR"
cp "$ROOT/reset.sh" "$PIPELINE_DIR/"

# 1) reset.sh <프로젝트> → state/<프로젝트>/ 만 초기화
( cd "$PIPELINE_DIR" && bash reset.sh alpha >/dev/null )
[ -f "$PIPELINE_DIR/state/alpha/handoff.json" ] && pass "reset alpha → state/alpha/ 생성" || fail "state/alpha 미생성"
( cd "$PIPELINE_DIR" && bash reset.sh beta >/dev/null )
printf 'X' >> "$PIPELINE_DIR/state/alpha/requirements.md"
( cd "$PIPELINE_DIR" && bash reset.sh beta >/dev/null )
assert_contains "$(cat "$PIPELINE_DIR/state/alpha/requirements.md")" "X" "beta reset이 alpha를 건드리지 않음"

# 2) 인자 없으면 에러 (전역 삭제 방지)
( cd "$PIPELINE_DIR" && bash reset.sh >/dev/null 2>&1 ); assert_eq "2" "$?" "인자 없는 reset은 exit 2"

# 3) prompts.sh가 STATE_DIR을 주입
export TARGET_REPO="$TMP/repo" STATE_DIR="$PIPELINE_DIR/state/alpha"
. "$ROOT/prompts.sh"
assert_contains "$(paths_header)" "state/alpha" "paths_header가 STATE_DIR 사용"

# 4) milestones.sh가 STATE_DIR의 backlog를 읽음
. "$ROOT/milestones.sh"
printf '## todo\n### T2\n## done\n### T1\n' > "$STATE_DIR/backlog.md"
assert_eq "1 2" "$(backlog_progress)" "backlog_progress가 격리된 state를 읽음"

echo; echo "state_isolation: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
