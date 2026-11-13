#!/usr/bin/env bash
# 올림푸스 마일스톤 진행도 알림 — run.sh가 source 한다. best-effort.
# 개입 요청(질문/승인/토큰대기)과 독립적으로, "파이프라인이 어디까지 왔는지"를
# 마일스톤 지점마다 폰(Gmail)으로 알린다. 기존 notify.py(SMTP) 재사용.
# 계약: 어떤 경우에도 비0을 반환하지 않는다 — 파이프라인을 절대 멈추지 않는다.

# state/backlog.md 파싱 → "done total" 두 숫자. best-effort(실패/부재 시 "0 0").
#   `## <섹션>` 아래의 `### <작업>` 헤더 수를 센다. `(없음)` 플레이스홀더는 ### 가 아니라 무시됨.
backlog_progress() {
  local f="${STATE_DIR:-$PIPELINE_DIR/state}/backlog.md"
  [ -f "$f" ] || { echo "0 0"; return 0; }
  awk '
    /^## /  { sec=$2; next }
    /^### / { t++; if (sec=="done") d++ }
    END     { printf "%d %d\n", d+0, t+0 }
  ' "$f" 2>/dev/null || echo "0 0"
}

# 특정 섹션의 작업 제목(### 줄, "### " 제거) 목록. 본문 조립용.
backlog_titles() {   # $1=섹션(todo|doing|done)
  local f="${STATE_DIR:-$PIPELINE_DIR/state}/backlog.md" want="${1:-todo}"
  [ -f "$f" ] || return 0
  awk -v want="$want" '
    /^## /  { sec=$2; next }
    /^### / { if (sec==want) print substr($0,5) }
  ' "$f" 2>/dev/null || true
}

# 발송 래퍼. $1=제목 $2=본문파일. 로그 1줄은 항상. 실패는 무시. 항상 0 반환.
milestone_notify() {   # <subject> <bodyfile>
  local subject="$1" bf="$2"
  echo "🔔 [milestone] $subject"
  if [ "${NOTIFY_MILESTONES:-1}" = "1" ] && [ -n "${SMTP_APP_PASSWORD:-}" ]; then
    local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # 응답 필요 여부를 메일마다 명시(2026-07-09 사용자 요구) — 마일스톤은 순수 알림.
    local mb; mb="$(mktemp 2>/dev/null)" || mb=""
    if [ -n "$mb" ]; then
      { printf 'ℹ️ 진행 알림입니다 — 회신 불필요. (질문·승인이 필요하면 별도 메일이 옵니다:\n'
        printf '   질문=GitHub 「## 답변」 편집 / 최종 승인=해당 메일에 답장 첫 줄 y·n)\n\n'
        cat "$bf"
      } > "$mb"
    else
      mb="$bf"
    fi
    NOTIFY_EMAIL="${NOTIFY_EMAIL:-}" SMTP_SENDER="${SMTP_SENDER:-}" SMTP_APP_PASSWORD="${SMTP_APP_PASSWORD:-}" \
      python3 "${NOTIFY_PY:-$root/notify.py}" --subject "$subject" --body-file "$mb" >&2 || true
    [ "$mb" != "$bf" ] && rm -f "$mb"
  fi
  return 0
}
