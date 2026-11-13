#!/usr/bin/env bash
# resilience.sh — claude 호출을 Claude Code 사용량 한도에 견디게 감싼다.
# run.sh에서 `. resilience.sh`로 소스. 순수 bash(3.2+), GNU/BSD 전용 플래그 없음.

# ── 구성 기본값(config.sh/env로 override) ──
: "${TOKEN_WAIT:=1}"                 # 1=기능 on, 0=기존처럼 감지 없이 진행
: "${TOKEN_RETRY_SEC:=1200}"         # 리셋시각 파싱 실패 시 재시도 간격(초)
: "${TOKEN_RESET_BUFFER_SEC:=60}"    # 파싱된 리셋시각에 더할 여유(초)
: "${TOKEN_WAIT_CHUNK_SEC:=1800}"    # 한 번 sleep 최대 길이(초)
: "${TOKEN_MAX_WAIT_SEC:=0}"         # 총 누적 대기 상한(초, 0=무제한)

# 사용량 한도 메시지인가? (종료코드 아닌 출력 패턴으로 판정)
is_usage_limit() {
  case "$1" in *"You've hit your"*) return 0 ;; *) return 1 ;; esac
}

# 리셋시각 문자열 → epoch(초). 실패하면 빈 출력. best-effort, 크로스플랫폼.
parse_reset_epoch() {
  local text="$1" t ep=""
  # "resets 3:45pm" 또는 "resets Mon 12:00am" 등에서 시각부 추출
  t="$(printf '%s' "$text" | sed -n 's/.*[Rr]esets \([A-Za-z0-9: ]*[ap]m\).*/\1/p' | head -1)"
  [ -n "$t" ] || return 0
  if date --version >/dev/null 2>&1; then
    ep="$(date -d "$t" +%s 2>/dev/null)"                    # GNU (WSL/Git Bash)
  else
    ep="$(date -j -f "%I:%M%p" "$t" +%s 2>/dev/null)"       # BSD (macOS), 시각-only 형태만
  fi
  case "$ep" in ''|*[!0-9]*) return 0 ;; *) printf '%s' "$ep" ;; esac
}

# 대기할 초 계산. 파싱되면 리셋까지, 아니면 재시도간격. 언제나 청크로 상한.
compute_wait() {
  local text="$1" now ep w
  now="$(date +%s)"
  ep="$(parse_reset_epoch "$text")"
  if [ -n "$ep" ] && [ "$ep" -gt "$now" ]; then
    w=$(( ep - now + TOKEN_RESET_BUFFER_SEC ))
  else
    w="$TOKEN_RETRY_SEC"
  fi
  [ "$w" -gt "$TOKEN_WAIT_CHUNK_SEC" ] && w="$TOKEN_WAIT_CHUNK_SEC"
  [ "$w" -lt 1 ] && w=1
  printf '%s' "$w"
}

# sleep 래퍼(테스트에서 override 가능)
token_sleep() { sleep "$1"; }

# best-effort 알림: 로그 1줄은 항상, SMTP 설정 있으면 notify.py도(실패 무시).
token_wait_notify() {
  echo "🔔 [token-wait] $1"
  [ -n "${SMTP_APP_PASSWORD:-}" ] || return 0
  local bf; bf="$(mktemp)"; { printf 'ℹ️ 진행 알림입니다 — 회신 불필요(자동 대기·재개).\n\n'; printf '%s\n' "$1"; } > "$bf"
  python3 "${PIPELINE_DIR:-.}/notify.py" --subject "[올림푸스] 토큰 대기" --body-file "$bf" >/dev/null 2>&1 || true
  rm -f "$bf"
}

# 인자에서 --model 값 추출(있으면 stdout, 없으면 빈 출력)
_extract_model() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) printf '%s' "${2:-}"; return ;;
      --model=*) printf '%s' "${1#--model=}"; return ;;
    esac
    shift
  done
}

# claude를 사용량 한도에 견디게 실행. 인자 = 실제 claude 인자.
claude_guarded() {
  if [ "${TOKEN_WAIT:-1}" != "1" ]; then claude "$@"; return $?; fi

  local out rc
  out="$(claude "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  is_usage_limit "$out" || return "$rc"          # 성공/한도-아닌 실패 → 그대로

  # 사용량 한도 감지 → 프로브 대기 루프
  local model waited=0 w last="$out"
  model="$(_extract_model "$@")"
  token_wait_notify "토큰 소진 감지 — 리셋까지 대기 후 자동 재개"
  while is_usage_limit "$last"; do
    w="$(compute_wait "$last")"
    if [ "${TOKEN_MAX_WAIT_SEC:-0}" -gt 0 ] && [ $(( waited + w )) -gt "${TOKEN_MAX_WAIT_SEC}" ]; then
      echo "⛔ [token-wait] 총 대기 상한(${TOKEN_MAX_WAIT_SEC}s) 초과 — 포기." >&2
      return 1
    fi
    echo "⏳ [token-wait] ${w}s 대기 후 재확인…" >&2
    token_sleep "$w"; waited=$(( waited + w ))
    last="$(claude -p ok ${model:+--model "$model"} 2>&1)"   # 경량 프로브
  done
  echo "▶ [token-wait] 한도 해제 — 실제 호출 재개." >&2
  token_wait_notify "한도 해제 — 작업 재개"
  out="$(claude "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  return "$rc"
}
