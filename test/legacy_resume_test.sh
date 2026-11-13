#!/usr/bin/env bash
# 구버전으로 진행 중이던 실행을 중지 → 풀 → 재시작하는 시나리오 대비 가드 검증.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── queue_automigrate_for ──
export PIPELINE_DIR="$TMP/olympus"; mkdir -p "$PIPELINE_DIR/state/runs" "$PIPELINE_DIR/spec/mid"
QUEUE_LIB=1 . "$ROOT/queue.sh"

# 1) 구 레이아웃 없음 → no-op(rc 0)
( PIPELINE_DIR="$TMP/none" QUEUE_LIB=1 . "$ROOT/queue.sh"; queue_automigrate_for mid )
assert_eq "0" "$?" "구 레이아웃 없으면 rc 0"

# 2) 구 레이아웃(진행 중 상태) → state/<프로젝트>/ 자동 이행, 내용 보존
printf '{"turn":"builder","status":"ready"}' > "$PIPELINE_DIR/state/handoff.json"
printf '# 요구사항\n- 진행중\n' > "$PIPELINE_DIR/state/requirements.md"
printf '중간 저널\n' > "$PIPELINE_DIR/state/progress.md"
queue_automigrate_for mid >/dev/null
assert_eq "0" "$?" "자동 이행 rc 0"
[ ! -f "$PIPELINE_DIR/state/handoff.json" ] && pass "루트 구 state 제거됨" || fail "루트 구 state 잔존"
assert_contains "$(cat "$PIPELINE_DIR/state/mid/requirements.md" 2>/dev/null)" "진행중" "requirements 보존"
assert_contains "$(cat "$PIPELINE_DIR/state/mid/progress.md" 2>/dev/null)" "중간 저널" "진행 저널 보존"
[ -d "$PIPELINE_DIR/state/mid/runs" ] && pass "runs/ 이동" || fail "runs/ 미이동"

# 3) 충돌(구+신 둘 다 존재) → rc 3, 아무것도 옮기지 않음
printf '{"old":1}' > "$PIPELINE_DIR/state/handoff.json"
( queue_automigrate_for mid >/dev/null 2>&1 )
assert_eq "3" "$?" "충돌 시 rc 3"
assert_contains "$(cat "$PIPELINE_DIR/state/handoff.json")" "old" "충돌 시 구 state 무이동"

# ── run.sh 가드 존재(소스 검사 — 실행은 claude 필요라 정적 확인) ──
RUN_SRC="$(cat "$ROOT/run.sh")"
assert_contains "$RUN_SRC" "PROJECT_EXPLICIT" "run.sh: 프로젝트 확정 방식 추적"
assert_contains "$RUN_SRC" "queue_automigrate_for \"\$PROJECT\"" "run.sh: 확정 시 자동 이행"
assert_contains "$RUN_SRC" "PROJECT=<이름> bash run.sh" "run.sh: 모호 시 중단+안내"

echo; echo "legacy_resume: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
