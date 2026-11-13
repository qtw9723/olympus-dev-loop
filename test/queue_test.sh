#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$TMP/olympus"; mkdir -p "$PIPELINE_DIR/spec/alpha" "$PIPELINE_DIR/spec/beta"
QUEUE_LIB=1 . "$ROOT/queue.sh"

# 1) add → queued 항목 생성 (spec 없으면 거부)
queue_add alpha >/dev/null; queue_add beta lite >/dev/null
assert_eq "2" "$(queue_get '.items|length')" "add 2건"
assert_eq "auto" "$(queue_get '.items[0].mode')" "기본 mode=auto"
assert_eq "lite" "$(queue_get '.items[1].mode')" "mode 지정"
queue_add nope >/dev/null 2>&1
assert_eq "2" "$(queue_get '.items|length')" "spec 없는 프로젝트 거부"

# 2) claim → 첫 queued가 running, worker 블록 기록
ID="$(queue_claim)"
assert_eq "running" "$(queue_item_get "$ID" '.status')" "claim → running"
assert_eq "alpha" "$(queue_item_get "$ID" '.project')" "배열 순서=우선순위"
assert_eq "$$" "$(queue_get '.worker.pid')" "worker.pid 기록"

# 3) item_set / request 존중(checkpoint)
queue_item_set "$ID" '.request="pause"'
export QUEUE_ITEM_ID="$ID"
( queue_checkpoint >/dev/null ); assert_eq "4" "$?" "pause 요청 → exit 4"
assert_eq "paused" "$(queue_item_get "$ID" '.status')" "checkpoint가 paused 기록"
queue_item_set "$ID" '.status="running"|.request="cancel"'
( queue_checkpoint >/dev/null ); assert_eq "5" "$?" "cancel 요청 → exit 5"
assert_eq "cancelled" "$(queue_item_get "$ID" '.status')" "checkpoint가 cancelled 기록"
unset QUEUE_ITEM_ID

# 4) 스테일 회수: 죽은 pid의 running 항목 → paused(stale)
queue_item_set "$ID" '.status="running"'
queue_edit '.worker={pid:999999,current_id:"'"$ID"'",heartbeat_at:"2026-01-01T00:00:00+0900"}'
queue_recover_stale >/dev/null
assert_eq "paused" "$(queue_item_get "$ID" '.status')" "스테일 running → paused"
assert_eq "stale" "$(queue_item_get "$ID" '.paused_reason')" "paused_reason=stale"

# 5) 락: 산 pid가 점유 중이면 edit 실패(rc=1), 죽은 pid 락은 자동 회수
mkdir "$PIPELINE_DIR/state/queue.lock"; echo $$ > "$PIPELINE_DIR/state/queue.lock/pid"
QUEUE_LOCK_MAX_TRIES=3 queue_edit '.version=1' 2>/dev/null
assert_eq "1" "$?" "락 점유 중 edit 실패(rc=1)"
rm -rf "$PIPELINE_DIR/state/queue.lock"
mkdir "$PIPELINE_DIR/state/queue.lock"; echo 999999 > "$PIPELINE_DIR/state/queue.lock/pid"
queue_edit '.version=1' && pass "죽은 pid 락은 자동 회수" || fail "죽은 락 미회수"

# 6) migrate + 레거시 가드
M="$TMP/legacy"; mkdir -p "$M/state/runs"
printf '{"turn":"metis"}' > "$M/state/handoff.json"; printf 'req' > "$M/state/requirements.md"
( PIPELINE_DIR="$M" QUEUE_LIB=1 . "$ROOT/queue.sh"; queue_guard_legacy 2>/dev/null )
assert_eq "2" "$?" "구 레이아웃 감지 시 가드 exit 2"
( PIPELINE_DIR="$M" QUEUE_LIB=1 . "$ROOT/queue.sh"; queue_migrate old >/dev/null )
[ -f "$M/state/old/handoff.json" ] && [ -d "$M/state/old/runs" ] && [ ! -f "$M/state/handoff.json" ] \
  && pass "migrate → state/old/ 이동" || fail "migrate 실패"

echo; echo "queue: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
