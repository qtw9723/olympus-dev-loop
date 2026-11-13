#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/state" "$PIPELINE_DIR/roles" "$PIPELINE_DIR/spec/proj"
export TARGET_REPO="$TMP/repo"
export SPEC_DIR="$PIPELINE_DIR/spec/proj"
export MODE="greenfield"
cp "$ROOT/roles/"*.md "$PIPELINE_DIR/roles/"
printf 'SPEC_BODY_MARKER 원본 기획서 본문\n'   > "$SPEC_DIR/01_기획.md"
printf 'QUESTION_MARKER builder 질문\n'        > "$PIPELINE_DIR/state/ask-planner.md"
printf 'FINDINGS_MARKER 범위밖 결함\n'         > "$PIPELINE_DIR/state/findings.md"
printf 'BACKLOG_MARKER T2 todo\n'              > "$PIPELINE_DIR/state/backlog.md"
printf 'TASK_MARKER T1 수용기준\n'             > "$PIPELINE_DIR/state/task.md"
printf 'PROGRESS_MARKER 완료: 절반\n'          > "$PIPELINE_DIR/state/progress.md"
printf 'FEEDBACK_MARKER 지적\n'                > "$PIPELINE_DIR/state/critic-feedback.md"
printf 'REQ_BODY_MARKER 요구사항 분석 본문\n'  > "$PIPELINE_DIR/state/requirements.md"

. "$ROOT/prompts.sh"

# ── metis M0 (재시작: requirements.md가 이미 채워짐) ──
P="$(metis_prompt M0)"
assert_contains     "$P" "$SPEC_DIR"        "M0: spec 경로 포함"
assert_contains     "$P" "이번 호출 모드: M0" "M0: 모드 힌트"
assert_not_contains "$P" "SPEC_BODY_MARKER" "M0: spec 본문 미인라인"
assert_not_contains "$P" "REQ_BODY_MARKER"  "M0: requirements 미인라인"
assert_contains     "$P" "재시작"           "M0 재개: 재시작 감지 문구"
assert_contains     "$P" "재분해를 하지 마라" "M0 재개: 재분석·재분해 금지 지시"

# ── metis M0 (신규: requirements.md 비어 있음) ──
: > "$PIPELINE_DIR/state/requirements.md"
P="$(metis_prompt M0)"
assert_contains     "$P" "요구사항 분석"     "M0 신규: 분석 지시"
assert_not_contains "$P" "재분해를 하지 마라" "M0 신규: 재개 지시 없음"
printf 'REQ_BODY_MARKER 요구사항 분석 본문\n' > "$PIPELINE_DIR/state/requirements.md"

# ── metis M1: 질문 큐만 인라인 ──
P="$(metis_prompt M1)"
assert_contains     "$P" "QUESTION_MARKER"  "M1: ask-planner 인라인"
assert_not_contains "$P" "FINDINGS_MARKER"  "M1: findings 미인라인"
assert_not_contains "$P" "SPEC_BODY_MARKER" "M1: spec 본문 미인라인"

# ── metis M2: findings+backlog만 인라인 ──
P="$(metis_prompt M2)"
assert_contains     "$P" "FINDINGS_MARKER"  "M2: findings 인라인"
assert_contains     "$P" "BACKLOG_MARKER"   "M2: backlog 인라인"
assert_not_contains "$P" "QUESTION_MARKER"  "M2: ask-planner 미인라인"
assert_contains     "$P" "progress.md"      "M2: progress 초기화 지시 언급"

# ── worker: task+progress+feedback만 인라인, requirements는 참조 ──
P="$(worker_prompt "$PIPELINE_DIR/roles/builder.md")"
assert_contains     "$P" "TASK_MARKER"      "worker: task 인라인"
assert_contains     "$P" "PROGRESS_MARKER"  "worker: progress 인라인"
assert_contains     "$P" "FEEDBACK_MARKER"  "worker: critic-feedback 인라인"
assert_not_contains "$P" "REQ_BODY_MARKER"  "worker: requirements 미인라인"
assert_not_contains "$P" "SPEC_BODY_MARKER" "worker: spec 본문 미인라인"

# ── 빈 핫 파일이어도 프롬프트 조립이 깨지지 않음 ──
: > "$PIPELINE_DIR/state/ask-planner.md"
P="$(metis_prompt M1)"
assert_contains "$P" "(비어 있음)" "M1: 빈 파일은 '(비어 있음)' 표시"

# ── run.sh 정적 검사: 세션 유지 잔재 없음 + prompts.sh 소스 + 모드 호출 ──
RUN_SRC="$(cat "$ROOT/run.sh")"
assert_not_contains "$RUN_SRC" "METIS_SID"    "run.sh: METIS_SID 제거"
assert_not_contains "$RUN_SRC" "--resume"     "run.sh: --resume 제거"
assert_not_contains "$RUN_SRC" "--session-id" "run.sh: --session-id 제거"
assert_contains "$RUN_SRC" "prompts.sh" "run.sh: prompts.sh 소스"
assert_contains "$RUN_SRC" "metis M0"   "run.sh: Phase0 → metis M0"
assert_contains "$RUN_SRC" "metis M1"   "run.sh: 질문 라우팅 → metis M1"
assert_contains "$RUN_SRC" "metis M2"   "run.sh: 다음 작업 → metis M2"
if bash -n "$ROOT/run.sh" 2>/dev/null; then pass "run.sh: 문법 OK"; else fail "run.sh: 문법 오류"; fi

# ── reset.sh: progress.md 초기화 ──
mkdir -p "$TMP/reset-pipe"; cp "$ROOT/reset.sh" "$TMP/reset-pipe/reset.sh"
bash "$TMP/reset-pipe/reset.sh" pipe >/dev/null
if [ -f "$TMP/reset-pipe/state/pipe/progress.md" ]; then pass "reset.sh: progress.md 생성"; else fail "reset.sh: progress.md 누락"; fi

# ── 역할 문서: 진행 저널 계약 ──
assert_contains "$(cat "$ROOT/roles/builder.md")" "progress.md" "builder.md: 진행 저널 지시"
assert_contains "$(cat "$ROOT/roles/critic.md")"  "progress.md" "critic.md: 진행 저널 지시"
assert_contains "$(cat "$ROOT/roles/metis.md")"   "progress.md" "metis.md: M2 진행 저널 초기화"

[ "${TESTS_FAIL:-0}" -eq 0 ]
