#!/usr/bin/env bash
# ui.sh autostart/stop — 백그라운드 멱등 기동·중복 방지·종료 검증
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; PORT=18965
cleanup(){ [ -f "$TMP/olympus/state/ui.pid" ] && kill "$(cat "$TMP/olympus/state/ui.pid")" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/spec/alpha"

# 1) 기동 — 서버가 뜨고 pid 파일이 남는다
OUT="$(bash "$ROOT/ui.sh" autostart "$PORT")"; RC=$?
assert_eq "0" "$RC" "autostart rc=0"
assert_contains "$OUT" "http://127.0.0.1:$PORT" "autostart가 URL 출력"
BODY="$(curl -sf -m 2 "http://127.0.0.1:$PORT/api/queue")"
assert_contains "$BODY" '"items"' "서버 응답(/api/queue)"
PID1="$(cat "$PIPELINE_DIR/state/ui.pid" 2>/dev/null)"
assert_eq "0" "$([ -n "$PID1" ]; echo $?)" "ui.pid 기록"

# 2) 멱등 — 재호출은 새 프로세스를 띄우지 않는다
OUT2="$(bash "$ROOT/ui.sh" autostart "$PORT")"; RC2=$?
assert_eq "0" "$RC2" "재호출 rc=0"
assert_contains "$OUT2" "이미 실행" "재호출은 이미-실행 안내"
assert_eq "$PID1" "$(cat "$PIPELINE_DIR/state/ui.pid")" "pid 불변(중복 기동 없음)"

# 3) stop — 서버 종료 + pid 파일 정리
bash "$ROOT/ui.sh" stop >/dev/null
# 종료까지 최대 5초 폴링. init이 고아 프로세스를 수거하지 않는 환경(컨테이너)에서는
# 종료된 프로세스가 좀비(Z)로 남아 kill -0이 성공하므로 좀비는 종료로 본다.
ALIVE=1
for _ in $(seq 1 25); do
  if ! kill -0 "$PID1" 2>/dev/null || ps -o stat= -p "$PID1" 2>/dev/null | grep -q '^Z'; then ALIVE=0; break; fi
  sleep 0.2
done
assert_eq "0" "$ALIVE" "stop이 서버 프로세스 종료"
[ -f "$PIPELINE_DIR/state/ui.pid" ] && PF=1 || PF=0
assert_eq "0" "$PF" "stop이 ui.pid 제거"

# 4) stale pid 파일이 남아도 재기동된다
echo "99999999" > "$PIPELINE_DIR/state/ui.pid"
OUT3="$(bash "$ROOT/ui.sh" autostart "$PORT")"; RC3=$?
assert_eq "0" "$RC3" "stale pid 후 재기동 rc=0"
BODY3="$(curl -sf -m 2 "http://127.0.0.1:$PORT/api/queue")"
assert_contains "$BODY3" '"items"' "재기동 서버 응답"

echo; echo "ui_autostart: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
