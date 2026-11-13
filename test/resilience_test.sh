#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

. "$ROOT/resilience.sh"

# ── 감지 ──
LIMIT="You've hit your session limit · resets 3:45pm"
if is_usage_limit "$LIMIT"; then pass "한도 메시지 감지"; else fail "한도 메시지 감지 실패"; fi
TESTS_RUN=$((TESTS_RUN+1))
if is_usage_limit "normal output, all good"; then fail "정상 출력을 한도로 오판"; else pass "정상 출력은 한도 아님"; fi
TESTS_RUN=$((TESTS_RUN+1))

# ── 대기 계산(파싱 폴백 + 상한) ──
( export TOKEN_RETRY_SEC=1200 TOKEN_WAIT_CHUNK_SEC=1800 TOKEN_RESET_BUFFER_SEC=60
  # 시각 문자열이 없으면 → TOKEN_RETRY_SEC
  W1="$(compute_wait "You've hit your weekly limit, try later")"
  [ "$W1" = "1200" ] && echo "  ✓ 파싱 불가 → TOKEN_RETRY_SEC" || { echo "  ✗ 파싱 불가 폴백 — got [$W1]"; exit 9; }
  # 어떤 경우에도 청크 상한을 넘지 않는다
  W2="$(compute_wait "You've hit your weekly limit · resets Mon 12:00am")"
  [ "$W2" -le 1800 ] && [ "$W2" -gt 0 ] && echo "  ✓ 대기값 청크 상한 이내(0<W≤1800): $W2" || { echo "  ✗ 상한 위반 — got [$W2]"; exit 9; }
) || fail "compute_wait 동작"
TESTS_RUN=$((TESTS_RUN+2))

# ── claude_guarded: 한도 감지 → 대기 → 재개 ──
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
# 스텁 claude: TOKEN_TEST_MODE=error면 한도-아닌 실패. 아니면 첫 N회 한도 후 정상.
if [ "${TOKEN_TEST_MODE:-limit}" = "error" ]; then
  echo "API Error: something unexpected" >&2; exit 1
fi
n=0; [ -f "$TOKEN_TEST_CNT" ] && n="$(cat "$TOKEN_TEST_CNT")"; n=$((n+1)); echo "$n" > "$TOKEN_TEST_CNT"
if [ "$n" -le "${TOKEN_TEST_LIMIT_N:-2}" ]; then
  echo "You've hit your session limit · resets 3:45pm" >&2; exit 1
fi
echo "OK task done"; exit 0
SH
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" TOKEN_TEST_CNT="$TMP/cnt"
export TOKEN_WAIT=1 TOKEN_RETRY_SEC=1 TOKEN_WAIT_CHUNK_SEC=1 TOKEN_MAX_WAIT_SEC=0
# 실제로 자지 않게 + 알림 무력화
token_sleep(){ echo x >> "$TMP/sleeps"; }
token_wait_notify(){ :; }

# 케이스 A: 한도 2회 후 해제 → 대기·재개해 최종 성공
: > "$TMP/cnt"; : > "$TMP/sleeps"
OUT="$(TOKEN_TEST_LIMIT_N=2 claude_guarded -p "heavy prompt" --model claude-opus-4-8)"; RC=$?
assert_eq "0" "$RC" "재개 후 최종 종료코드 0"
assert_contains "$OUT" "OK task done" "재개 후 실제 출력 반환"
NS="$(wc -l < "$TMP/sleeps" | tr -d ' ')"
case "$NS" in 0) fail "대기가 한 번도 안 일어남" ;; *) pass "대기 발생(${NS}회)" ;; esac
TESTS_RUN=$((TESTS_RUN+1))

# 케이스 B: TOKEN_WAIT=0이면 한도 실패를 그대로 반환, 대기 없음
: > "$TMP/cnt"; : > "$TMP/sleeps"
( TOKEN_WAIT=0 TOKEN_TEST_LIMIT_N=99 claude_guarded -p heavy ) ; RC=$?
assert_eq "1" "$RC" "TOKEN_WAIT=0이면 한도 실패 그대로 반환"
assert_eq "0" "$(wc -l < "$TMP/sleeps" | tr -d ' ')" "TOKEN_WAIT=0이면 대기 안 함"

# 케이스 C: 한도-아닌 실패는 즉시 반환, 대기 없음
: > "$TMP/cnt"; : > "$TMP/sleeps"
OUT="$(TOKEN_TEST_MODE=error claude_guarded -p heavy)"; RC=$?
assert_eq "1" "$RC" "한도-아닌 실패는 즉시 반환"
assert_eq "0" "$(wc -l < "$TMP/sleeps" | tr -d ' ')" "한도-아닌 실패엔 대기 안 함"

# ── 하한 클램프: 노브 0으로 오설정해도 최소 1 반환(busy-loop 방지) ──
( export TOKEN_RETRY_SEC=0 TOKEN_WAIT_CHUNK_SEC=0
  W="$(compute_wait "You've hit your limit, no time")"
  [ "$W" -ge 1 ] && echo "  ✓ 하한 클램프(≥1)" || { echo "  ✗ 하한 클램프 — got [$W]"; exit 9; }
) || fail "compute_wait 하한 클램프"
TESTS_RUN=$((TESTS_RUN+1))

# ── run.sh 배선 정적 검증 ──
RUNSRC="$(cat "$ROOT/run.sh")"
assert_contains "$RUNSRC" "resilience.sh" "run.sh가 resilience.sh를 소스"
assert_contains "$RUNSRC" "claude_guarded -p" "metis/worker가 claude_guarded 경유"
assert_contains "$RUNSRC" "CLAUDE_CODE_RETRY_WATCHDOG" "429/529 워치독 export"

[ "${TESTS_FAIL:-0}" -eq 0 ]
