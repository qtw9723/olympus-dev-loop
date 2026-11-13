#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "이대로 머지?" > "$TMP/body.txt"
OUT="$(SMTP_SENDER=you@example.com SMTP_APP_PASSWORD=dummy NOTIFY_EMAIL=you@example.com \
  python3 "$ROOT/notify.py" --subject "[올림푸스] 대기: approval — 최종 승인" --body-file "$TMP/body.txt" --dry-run)"
assert_contains "$OUT" "Subject: [올림푸스] 대기: approval — 최종 승인" "제목 헤더"
assert_contains "$OUT" "To: you@example.com" "수신 헤더"
assert_contains "$OUT" "X-Priority: 1" "우선순위 헤더"
assert_contains "$OUT" "이대로 머지?" "본문 포함"

# 비밀 없으면 비0 종료
SMTP_APP_PASSWORD="" python3 "$ROOT/notify.py" --subject x --body-file "$TMP/body.txt" >/dev/null 2>&1
assert_eq "1" "$?" "앱비번 없으면 비0 종료"

# 실제 발송 실패(접속 자체가 안 되는 로컬 포트)는 exit 2로 구분되어야 하며,
# 비밀 없음(exit 1)과 혼동되어 조용히 스킵(0)으로 매핑되면 안 된다.
SEND_OUT="$(SMTP_SENDER=x@x SMTP_APP_PASSWORD=dummy SMTP_HOST=127.0.0.1 SMTP_PORT=1 \
  python3 "$ROOT/notify.py" --subject x --body-file "$TMP/body.txt" 2>&1)"
SEND_RC=$?
assert_eq "2" "$SEND_RC" "실발송 실패(접속 거부)는 exit 2"
case "$SEND_OUT" in
  *dummy*) fail "발송 실패 로그에 비밀번호가 노출됨" ;;
  *) pass "발송 실패 로그에 비밀번호 미노출" ;;
esac
TESTS_RUN=$((TESTS_RUN+1))

# --link 주면 폰에서 열 GitHub 문서 버튼/URL이 메일에 포함되어야 한다.
LINK="https://github.com/<owner>/olympus-inbox/blob/main/pending/20260703-094951.md"
LOUT="$(SMTP_SENDER=you@example.com SMTP_APP_PASSWORD=dummy NOTIFY_EMAIL=you@example.com \
  python3 "$ROOT/notify.py" --subject "[올림푸스] 대기: blocker — Phase0 블로커" \
  --body-file "$TMP/body.txt" --link "$LINK" --dry-run)"
assert_contains "$LOUT" "$LINK" "링크 URL 포함(플레인 폴백)"
assert_contains "$LOUT" "GitHub에서 답변하기" "버튼 라벨 포함"
assert_contains "$LOUT" "이대로 머지?" "링크 있어도 본문 유지"

# --link 없으면 버튼/링크 문구가 없어야 한다(기존 동작 유지).
NOUT="$(SMTP_SENDER=you@example.com SMTP_APP_PASSWORD=dummy NOTIFY_EMAIL=you@example.com \
  python3 "$ROOT/notify.py" --subject x --body-file "$TMP/body.txt" --dry-run)"
case "$NOUT" in
  *"GitHub에서 답변하기"*) fail "링크 없는데 버튼이 노출됨" ;;
  *) pass "링크 없으면 버튼 없음" ;;
esac
TESTS_RUN=$((TESTS_RUN+1))

[ "${TESTS_FAIL:-0}" -eq 0 ]
