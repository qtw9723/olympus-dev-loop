#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 가짜 원격(bare) + 초기 커밋 — 이 머신의 init.defaultBranch=main. seed push와
# INBOX_DIR clone이 같은 브랜치(main)를 쓰도록 명시적으로 통일한다.
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/seed"
( cd "$TMP/seed" && mkdir -p pending done && touch pending/.gitkeep done/.gitkeep \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm init \
  && git push -q origin HEAD:main )

# 테스트용 INBOX_DIR 클론(같은 브랜치=main, 업스트림 트래킹 생성) + 빠른 폴링
export INBOX_DIR="$TMP/inbox"; git clone -q -b main "$TMP/remote.git" "$INBOX_DIR"
export POLL_SEC=1 POLL_TIMEOUT_SEC=20 REMOTE=1 NOTIFY_EMAIL="x@x"
# 알림은 테스트에서 무력화(네트워크 금지) — remote_notify는 Task 5에서 정의될 예정
remote_notify(){ return 0; }
. "$ROOT/remote.sh"
remote_notify(){ return 0; }   # source 후 재정의(오버라이드 유지)

# 백그라운드 "사람": 3초 뒤 pending 파일에 답 채우고 push
( sleep 3
  cd "$INBOX_DIR" && git pull -q --ff-only
  f="$(ls pending/*.md | head -1)"
  printf '\ny\n' >> "$f"
  git -c user.email=h@h -c user.name=human commit -qam "answer" && git push -q ) &

echo "머지할까?" > "$TMP/body.txt"
ANS="$(remote_ask "20260702-testid" "approval" "최종 승인" "$TMP/body.txt")"; RC=$?
assert_eq "0" "$RC" "remote_ask 정상 반환"
assert_eq "y" "$ANS" "사람 답 y 수신"
wait
# done/으로 이동됐는지
( cd "$INBOX_DIR" && git pull -q --ff-only )
[ -f "$INBOX_DIR/done/20260702-testid.md" ] && pass "done/으로 이동" || fail "done/ 이동 실패"

# 타임아웃 경로: 아무도 답 안 함 → 반환 3
export POLL_TIMEOUT_SEC=2
echo "무응답질문" > "$TMP/b2.txt"
remote_ask "20260702-timeout" "blocker" "T" "$TMP/b2.txt" >/dev/null; RC2=$?
assert_eq "3" "$RC2" "타임아웃 시 반환 3"

echo "remote_enabled 테스트"
REMOTE=1 remote_enabled; assert_eq "0" "$?" "REMOTE=1이면 remote_enabled 0"
REMOTE=0 remote_enabled; assert_eq "1" "$?" "REMOTE=0이면 remote_enabled 비0"

[ "${TESTS_FAIL:-0}" -eq 0 ]
