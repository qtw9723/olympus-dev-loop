#!/usr/bin/env bash
# milestones.sh 단위 테스트 (helpers.sh 스타일, bats 미사용)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# milestones.sh 로드 (PIPELINE_DIR 를 픽스처 루트로 오버라이드)
PIPELINE_DIR="$TMP"; . "$ROOT/milestones.sh"

mkdir -p "$TMP/state"

# ── backlog_progress: todo 2 · doing 1 · done 3 → "3 6" ──
cat > "$TMP/state/backlog.md" <<'EOF'
# 백로그
## doing
### D1 — 진행중 작업
## todo
### A1 — 할 일 1
### A2 — 할 일 2
## done
### T1 — 완료 1
### T2 — 완료 2
### T3 — 완료 3
EOF
assert_eq "3 6" "$(backlog_progress)" "backlog_progress: done=3 total=6"

# ── (없음) 플레이스홀더만 있는 섹션은 0으로 계산 ──
cat > "$TMP/state/backlog.md" <<'EOF'
# 백로그
## doing
(없음)
## todo
(없음)
## done
### T1 — 완료 1
EOF
assert_eq "1 1" "$(backlog_progress)" "(없음) 플레이스홀더는 미집계 (done=1 total=1)"

# ── backlog_titles ──
assert_eq "T1 — 완료 1" "$(backlog_titles done)" "backlog_titles done"
assert_eq "" "$(backlog_titles todo)" "backlog_titles todo(없음)=빈값"

# ── 파일 없으면 "0 0", 비0 종료 아님 ──
rm -f "$TMP/state/backlog.md"
OUT="$(backlog_progress)"; RC=$?
assert_eq "0 0" "$OUT" "파일 없으면 0 0"
assert_eq "0" "$RC" "파일 없어도 exit 0"

# ── milestone_notify: 비밀 없으면 0 반환 + 로그 1줄 ──
echo "본문" > "$TMP/body.txt"
OUT="$(SMTP_APP_PASSWORD="" milestone_notify "[올림푸스] 테스트 제목" "$TMP/body.txt")"; RC=$?
assert_eq "0" "$RC" "SMTP 비밀 없으면 exit 0(무중단 계약)"
assert_contains "$OUT" "🔔 [milestone] [올림푸스] 테스트 제목" "로그 1줄 출력"

# ── NOTIFY_MILESTONES=0 이면 notify 대상 미호출(로그만) ──
REC="$TMP/called.txt"; : > "$REC"
cat > "$TMP/stub.py" <<EOF
import sys
open("$REC","a").write(" ".join(sys.argv[1:])+"\n")
EOF
OUT="$(NOTIFY_MILESTONES=0 SMTP_APP_PASSWORD=dummy NOTIFY_PY="$TMP/stub.py" \
       milestone_notify "[올림푸스] 꺼짐" "$TMP/body.txt")"; RC=$?
assert_eq "0" "$RC" "NOTIFY_MILESTONES=0 exit 0"
assert_eq "" "$(cat "$REC")" "NOTIFY_MILESTONES=0 이면 notify 미호출"
assert_contains "$OUT" "🔔 [milestone]" "꺼져도 로그는 출력"

# ── NOTIFY_MILESTONES=1 + 비밀 있으면 notify_py 스텁이 인자와 함께 호출됨 ──
: > "$REC"
NOTIFY_MILESTONES=1 SMTP_APP_PASSWORD=dummy NOTIFY_PY="$TMP/stub.py" \
  milestone_notify "[올림푸스] 켜짐 제목" "$TMP/body.txt" >/dev/null 2>&1
assert_contains "$(cat "$REC")" "--subject [올림푸스] 켜짐 제목" "notify_py 호출 인자에 제목"
assert_contains "$(cat "$REC")" "--body-file" "notify_py 호출 인자에 body-file"

echo; echo "milestones: $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"
[ "$TESTS_FAIL" -eq 0 ]
