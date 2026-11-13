#!/usr/bin/env bash
# 결정 패널 ops — decisions 목록·answer(답변+자동 재개)·가드·queue.sh 상호운용 검증
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/spec/alpha" "$PIPELINE_DIR/spec/beta"
OPS="$ROOT/ui/queue_ops.py"
ops(){ python3 "$OPS" "$@"; }
QUEUE_LIB=1 . "$ROOT/queue.sh"

# 준비: alpha=blocker로 눕은 항목(질문 있음), beta=queued
A_ID="$(ops add alpha | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
B_ID="$(ops add beta | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
C_ID="$(queue_claim)"   # alpha가 running으로
assert_eq "$A_ID" "$C_ID" "claim=alpha"
queue_item_set "$A_ID" '.status="paused"|.paused_reason="blocker"|.result="blocked:질문 확인 필요"'
mkdir -p "$PIPELINE_DIR/state/alpha"
printf '1. 어떤 DB를 쓸까요?\n2. 인증은 필요한가요?\n' > "$PIPELINE_DIR/state/alpha/questions.md"
printf '%s\n' '- 로그 보존 기간은 가정(30일)으로 진행' > "$PIPELINE_DIR/state/alpha/open-questions.md"

# 0) 주석 플레이스홀더만 있는 open-questions는 목록 제외
mkdir -p "$PIPELINE_DIR/state/beta"
printf '<!-- 초기 상태: 비어 있음 -->\n' > "$PIPELINE_DIR/state/beta/open-questions.md"

# 1) decisions 목록
D="$(ops decisions)"
assert_contains "$D" '어떤 DB를 쓸까요?' "blocker 질문 포함"
assert_contains "$D" "$A_ID" "blocker 항목 id 포함"
assert_contains "$D" '로그 보존 기간' "open_questions 포함"
assert_not_contains "$D" "$B_ID" "queued 항목은 결정 대기 아님"
assert_not_contains "$D" '초기 상태' "주석뿐인 open-questions 제외"

# 2) answer 가드
ops answer q-없는id "PostgreSQL" >/dev/null 2>&1;  assert_eq "1" "$?" "미존재 id 거부"
ops answer "$B_ID" "PostgreSQL" >/dev/null 2>&1;   assert_eq "1" "$?" "queued 항목 answer 거부"
ops answer "$A_ID" "" >/dev/null 2>&1;             assert_eq "1" "$?" "빈 답 거부"
ops answer "$A_ID" "   " >/dev/null 2>&1;          assert_eq "1" "$?" "공백 답 거부"
assert_eq "paused" "$(queue_item_get "$A_ID" '.status')" "가드 실패 시 상태 불변"

# 3) answer 정상 — 파일 포맷 + 자동 재개
ops answer "$A_ID" "PostgreSQL로, 인증은 없이 갑니다" >/dev/null
HA="$PIPELINE_DIR/state/alpha/human-answers.md"
assert_contains "$(cat "$HA")" '## [blocker] UI 답변' "human-answers 헤더 포맷"
assert_contains "$(cat "$HA")" '어떤 DB를 쓸까요?' "질문 원문 포함"
assert_contains "$(cat "$HA")" 'PostgreSQL로, 인증은 없이 갑니다' "사람 답 포함"
assert_eq "queued" "$(queue_item_get "$A_ID" '.status')" "답변 후 자동 재개(queued)"
assert_eq "null" "$(queue_item_get "$A_ID" '.paused_reason')" "paused_reason 정리"
assert_eq "null" "$(queue_item_get "$A_ID" '.request')" "request 정리"

# 4) 재개 후에는 결정 대기에서 사라짐
D2="$(ops decisions)"
assert_not_contains "$D2" "$A_ID" "답변 후 blockers에서 제거"

# 5) paused(human)은 블로커가 아님 — answer 거부
queue_item_set "$B_ID" '.status="paused"|.paused_reason="human"'
ops answer "$B_ID" "답" >/dev/null 2>&1;  assert_eq "1" "$?" "paused(human) answer 거부"

# 6) questions.md 없는 blocker도 답변 가능(질문 자리 표기)
queue_item_set "$B_ID" '.paused_reason="blocker"'
ops answer "$B_ID" "그냥 진행해주세요" >/dev/null
assert_contains "$(cat "$PIPELINE_DIR/state/beta/human-answers.md")" 'questions.md 없음' "질문 파일 없음 표기"
assert_eq "queued" "$(queue_item_get "$B_ID" '.status')" "질문 파일 없어도 재개"

echo; echo "ui_decisions: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
