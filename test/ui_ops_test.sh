#!/usr/bin/env bash
# ui/queue_ops.py — 소유권 가드·조작·queue.sh 상호운용 검증
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/spec/alpha" "$PIPELINE_DIR/spec/beta" "$PIPELINE_DIR/spec/gamma"
OPS="$ROOT/ui/queue_ops.py"
ops(){ python3 "$OPS" "$@"; }
QUEUE_LIB=1 . "$ROOT/queue.sh"

# 1) add — 생성·거부
A_ID="$(ops add alpha | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
ops add beta lite >/dev/null
assert_eq "2" "$(queue_get '.items|length')" "add 2건 (queue.sh가 읽음)"
assert_eq "queued" "$(queue_item_get "$A_ID" '.status')" "생성 status=queued"
assert_eq "lite" "$(queue_get '.items[1].mode')" "mode 지정"
ops add nope >/dev/null 2>&1;        assert_eq "1" "$?" "spec 없는 프로젝트 거부"
ops add alpha bogus >/dev/null 2>&1; assert_eq "1" "$?" "잘못된 mode 거부"
ops add '../etc' >/dev/null 2>&1;    assert_eq "1" "$?" "경로문자 프로젝트명 거부"

# 2) reorder — 순열 적용·불일치 거부
B_ID="$(queue_get '.items[1].id')"
ops reorder "$B_ID" "$A_ID" >/dev/null
assert_eq "beta" "$(queue_get '.items[0].project')" "reorder 적용"
ops reorder "$B_ID" >/dev/null 2>&1;           assert_eq "1" "$?" "id 누락 reorder 거부"
ops reorder "$B_ID" "$A_ID" q-x >/dev/null 2>&1; assert_eq "1" "$?" "미지 id reorder 거부"

# 3) mode 변경 — queued만
ops mode "$A_ID" full >/dev/null
assert_eq "full" "$(queue_item_get "$A_ID" '.mode')" "mode 변경 적용"

# 4) 소유권 가드 — running 항목 (queue.sh claim으로 만든 실제 running)
R_ID="$(queue_claim)"
assert_eq "$B_ID" "$R_ID" "claim=첫 queued(beta)"
ops remove "$R_ID" >/dev/null 2>&1;      assert_eq "1" "$?" "running 삭제 거부"
ops mode "$R_ID" lite >/dev/null 2>&1;   assert_eq "1" "$?" "running mode 변경 거부"
ops resume "$A_ID" >/dev/null 2>&1;      assert_eq "1" "$?" "queued에 resume 거부"
ops request "$A_ID" pause >/dev/null 2>&1; assert_eq "1" "$?" "running 아닌 항목 request 거부"

# 5) request → queue_checkpoint 존중 (기존 계약 접점)
ops request "$R_ID" pause >/dev/null
assert_eq "pause" "$(queue_item_get "$R_ID" '.request')" "request=pause 기록"
export QUEUE_ITEM_ID="$R_ID"
( queue_checkpoint >/dev/null ); assert_eq "4" "$?" "checkpoint가 pause 존중(exit 4)"
assert_eq "paused" "$(queue_item_get "$R_ID" '.status')" "checkpoint → paused"
unset QUEUE_ITEM_ID

# 6) resume — paused→queued + reason/request 정리
ops resume "$R_ID" >/dev/null
assert_eq "queued" "$(queue_item_get "$R_ID" '.status')" "resume → queued"
assert_eq "null" "$(queue_item_get "$R_ID" '.paused_reason // "null"')" "paused_reason 정리"

# 7) remove — 비running 삭제
ops remove "$A_ID" >/dev/null
assert_eq "1" "$(queue_get '.items|length')" "remove 적용"

# 8) snapshot — 파생값·프로젝트 목록
SNAP="$(ops snapshot)"
assert_contains "$SNAP" '"projects": ["alpha", "beta", "gamma"]' "spec/ 프로젝트 목록"
assert_contains "$SNAP" '"stale": false' "워커 없음 → stale=false"
queue_edit '.worker={pid:999999,current_id:"x",heartbeat_at:"2026-01-01T00:00:00+0900"}'
assert_contains "$(ops snapshot)" '"stale": true' "죽은 pid → stale=true"

# 9) 구 레이아웃 가드
printf '{}' > "$PIPELINE_DIR/state/handoff.json"
ops add gamma >/dev/null 2>&1; assert_eq "1" "$?" "구 레이아웃 감지 시 add 거부"
rm "$PIPELINE_DIR/state/handoff.json"

# 10) detail — handoff + 로그 tail
mkdir -p "$PIPELINE_DIR/state/beta/runs"
printf '{"turn":"metis","round":1}' > "$PIPELINE_DIR/state/beta/handoff.json"
printf 'line1\nline2\n' > "$PIPELINE_DIR/state/beta/runs/run-1.log"
D="$(ops detail beta)"
assert_contains "$D" '"round": 1' "detail handoff 포함"
assert_contains "$D" 'line2' "detail 로그 tail 포함"
# 큰 로그도 마지막 N줄만 (seek 기반 tail — 전체 읽기 금지 회귀 방지)
for i in $(seq 1 3000); do printf 'L%04dx\n' "$i"; done > "$PIPELINE_DIR/state/beta/runs/run-2.log"
DBIG="$(ops detail beta)"
assert_contains "$DBIG" 'L3000x' "큰 로그 마지막 줄 포함"
assert_not_contains "$DBIG" 'L0001x' "큰 로그 첫 줄 제외"
ops detail '../x' >/dev/null 2>&1; assert_eq "1" "$?" "detail 경로문자 거부"

echo; echo "ui_ops: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
