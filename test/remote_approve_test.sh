#!/usr/bin/env bash
# remote_approve_email: 토큰 subject 생성 + y/n 정규화 전파 + rc(0/3/4/5) 전파.
# 실제 IMAP은 _inbox_await 스텁으로 대체(네트워크 금지).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

export SMTP_SENDER="you@example.com" POLL_TIMEOUT_SEC=1 POLL_SEC=1
remote_notify(){ return 0; }          # 메일 발송 무력화
. "$ROOT/remote.sh"
remote_notify(){ return 0; }          # source 후 재정의 유지

CAP="$TMP/cap"
# 스텁: 받은 token/from을 기록하고, 파일 STUB_OUT/STUB_RC로 결과 제어
_inbox_await(){ printf '%s %s\n' "$1" "$2" > "$CAP"; printf '%s' "$(cat "$TMP/out")"; return "$(cat "$TMP/rc")"; }

echo "머지 승인?" > "$TMP/q"

# (a) y / rc0
printf 'y' > "$TMP/out"; printf '0' > "$TMP/rc"
A="$(remote_approve_email "20260703-111111" "$TMP/q")"; RC=$?
assert_eq "y" "$A" "y 전파"; assert_eq "0" "$RC" "rc0 전파"
assert_contains "$(cat "$CAP")" "OLY-20260703-111111" "토큰 OLY-<id> 전달"
assert_contains "$(cat "$CAP")" "you@example.com" "APPROVE_FROM=SMTP_SENDER 전달"

# (b) n / rc0
printf 'n' > "$TMP/out"; printf '0' > "$TMP/rc"
A="$(remote_approve_email "20260703-222222" "$TMP/q")"; RC=$?
assert_eq "n" "$A" "n 전파"; assert_eq "0" "$RC" "rc0 전파(n)"

# (c) 타임아웃: 빈 답 / rc3
printf '' > "$TMP/out"; printf '3' > "$TMP/rc"
A="$(remote_approve_email "20260703-333333" "$TMP/q")"; RC=$?
assert_eq "" "$A" "타임아웃 빈 stdout"; assert_eq "3" "$RC" "rc3 전파(타임아웃)"

# (d) IMAP 불가: rc4 (폴백 신호)
printf '' > "$TMP/out"; printf '4' > "$TMP/rc"
A="$(remote_approve_email "20260703-444444" "$TMP/q")"; RC=$?
assert_eq "4" "$RC" "rc4 전파(IMAP 비밀없음 → 폴백)"

# (e) APPROVE_FROM 오버라이드
printf 'y' > "$TMP/out"; printf '0' > "$TMP/rc"
APPROVE_FROM="boss@corp.com" remote_approve_email "20260703-555555" "$TMP/q" >/dev/null
assert_contains "$(cat "$CAP")" "boss@corp.com" "APPROVE_FROM 오버라이드 반영"

# (f) 회귀: set -u에서 링크 없이 remote_notify 호출이 unbound array로 안 터짐
#     (macOS bash 3.2). 비밀 없으면 notify.py exit 1 → remote_notify 0.
( set -u
  unset SMTP_APP_PASSWORD
  . "$ROOT/remote.sh"
  remote_notify "제목" "본문"; echo "$?" > "$TMP/nrc" ) 2>/dev/null
assert_eq "0" "$(cat "$TMP/nrc")" "set -u·링크없음 remote_notify 안 터지고 0(비밀없음 스킵)"

[ "${TESTS_FAIL:-0}" -eq 0 ]
