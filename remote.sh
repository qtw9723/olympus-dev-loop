# 올림푸스 원격 결정 브리지 — run.sh가 source. 순수 함수 우선.

# ## 답변 섹션에서 HTML 주석을 제거하고 남은 내용을 trim해 반환. 없으면 빈 문자열.
_answer_from_file(){
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  awk '
    /^## 답변/ {grab=1; next}
    /^## / {grab=0}
    grab {print}
  ' "$f" \
  | sed -E 's/<!--.*-->//g' \
  | sed -E '/<!--/,/-->/d' \
  | sed -E 's/[[:space:]]+$//' \
  | sed -E 's/^[[:space:]]+//' \
  | awk 'NF{p=1} p' \
  | sed '/^[[:space:]]*$/d'
}

# pending 파일 작성. created는 호출부에서 SOURCE_DATE(=date) 주입 가능하나 기본은 date.
_write_pending(){
  local path="$1" id="$2" type="$3" title="$4" bodyfile="$5"
  local created; created="$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "$id")"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$id"
    printf 'type: %s\n' "$type"
    printf 'created: %s\n' "$created"
    printf 'title: %s\n' "$title"
    printf -- '---\n\n'
    printf '## 질문\n'
    cat "$bodyfile"
    printf '\n\n## 답변\n'
    printf '<!-- 아래에 답을 쓰고 commit 하세요. approval이면 y 또는 n -->\n'
  } > "$path"
}

remote_enabled(){ [ "${REMOTE:-0}" = "1" ]; }

# best-effort 알림. 비밀 없으면 조용히 0, 발송 시도 실패면 비0(호출부가 로깅).
# notify.py exit code 계약: 1=비밀 없음(설정 안 됨, 정상 스킵) / 2=실제 발송 실패
# (SMTP 접속·인증·전송 예외 — 호출부가 "⚠️ 알림 발송 실패"로 크게 로깅해야 함).
# 조용히 삼키지 않는다: 1만 0으로 매핑하고, 2 이상은 그대로 비0 반환해 전파한다.
# inbox 내 상대경로(예: pending/<id>.md)를 GitHub 웹 문서 URL로 변환.
# origin 리모트에서 owner/repo와 현재 브랜치를 유추. 못 구하면 빈 문자열.
_inbox_web_url(){  # <relpath>
  local rel="$1" origin branch base
  origin="$(git -C "$INBOX_DIR" remote get-url origin 2>/dev/null)" || return 0
  [ -n "$origin" ] || return 0
  branch="$(git -C "$INBOX_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"; [ -n "$branch" ] || branch="main"
  # git@github.com:owner/repo.git  또는  https://github.com/owner/repo(.git)  → https://github.com/owner/repo
  base="$(printf '%s' "$origin" | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##')"
  printf '%s/blob/%s/%s' "$base" "$branch" "$rel"
}

remote_notify(){
  local subject="$1" body="$2" link="${3:-}"
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local bf; bf="$(mktemp)"; printf '%s\n' "$body" > "$bf"
  local link_arg=()
  [ -n "$link" ] && link_arg=(--link "$link")
  # 빈 배열 확장은 macOS 기본 bash 3.2 + set -u에서 "unbound variable"로 터진다.
  # "${arr[@]+"${arr[@]}"}" 관용구로 비어 있으면 아무것도 확장하지 않게 한다.
  NOTIFY_EMAIL="${NOTIFY_EMAIL:-}" SMTP_SENDER="${SMTP_SENDER:-}" SMTP_APP_PASSWORD="${SMTP_APP_PASSWORD:-}" \
    python3 "$root/notify.py" --subject "$subject" --body-file "$bf" "${link_arg[@]+"${link_arg[@]}"}" >&2
  local rc=$?; rm -f "$bf"
  [ "$rc" -eq 1 ] && return 0   # 비밀 없음(exit 1)=스킵은 정상
  return "$rc"                  # 실제 발송 실패(exit 2)는 비0로 전파 → remote_ask가 로깅
}

# pending push → 폴링 → 답 감지 시 stdout에 답+반환0, 타임아웃 시 반환3.
remote_ask(){
  local id="$1" type="$2" title="$3" bodyfile="$4"
  local pend="pending/${id}.md" done="done/${id}.md"
  ( cd "$INBOX_DIR" && git pull -q --ff-only 2>/dev/null || true )
  _write_pending "$INBOX_DIR/$pend" "$id" "$type" "$title" "$bodyfile"
  ( cd "$INBOX_DIR" && git add "$pend" \
    && git -c user.email=olympus@local -c user.name=olympus commit -qm "ask $id ($type)" \
    && git push -q ) || echo "⚠️ inbox push 실패(id=$id) — 로컬 파일은 있음" >&2
  # 메일엔 "어디서·어떻게 응답하는지"를 반드시 명시한다(2026-07-09 사용자 요구 — 안내 없어 혼동).
  local ask_body; ask_body="$(mktemp)"
  { printf '━━ 응답 방법 ━━\n'
    printf '⚠️ 이 메일에 답장해도 반영되지 않습니다.\n'
    printf '▶ 아래 링크(GitHub 문서)를 열어 「## 답변」 섹션에 답을 적고 저장(커밋)하세요.\n'
    printf '   폴링이 감지해 자동으로 이어갑니다. (모바일은 GitHub 앱에서 편집)\n'
    printf '━━━━━━━━━━━━\n\n'
    cat "$bodyfile"
  } > "$ask_body"
  remote_notify "[올림푸스] 대기: ${type} — ${title}" "$(cat "$ask_body")" "$(_inbox_web_url "$pend")" || \
    echo "⚠️ 알림 발송 실패(id=$id) — 폴링은 계속" >&2
  rm -f "$ask_body"

  local waited=0 answer=""
  while :; do
    ( cd "$INBOX_DIR" && git pull -q --ff-only 2>/dev/null || true )
    answer="$(_answer_from_file "$INBOX_DIR/$pend")"
    if [ -n "$answer" ]; then
      ( cd "$INBOX_DIR" && git mv "$pend" "$done" 2>/dev/null \
        && git -c user.email=olympus@local -c user.name=olympus commit -qm "answered $id" \
        && git push -q ) || echo "⚠️ done 이동 push 실패(id=$id)" >&2
      printf '%s' "$answer"; return 0
    fi
    waited=$((waited + POLL_SEC))
    [ "$waited" -ge "$POLL_TIMEOUT_SEC" ] && return 3
    sleep "$POLL_SEC"
  done
}

# ── 최종 승인 전용 경량 경로: Gmail 답장(IMAP) ──
# 블로커/의도질문은 remote_ask(GitHub) 그대로. 최종 승인만 이 경로로 갈아끼운다.

# inbox_imap.py --await 얇은 래퍼(테스트에서 오버라이드 가능). IMAP 비밀은 SMTP와 공유.
# stdout: y|n / rc: 0 감지·3 타임아웃·4 비밀없음·5 접속실패
_inbox_await(){  # <token> <from>
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  IMAP_USER="${SMTP_SENDER:-}" IMAP_PASS="${SMTP_APP_PASSWORD:-}" \
    python3 "$root/inbox_imap.py" --await --token "$1" --from "$2" \
      --timeout "${POLL_TIMEOUT_SEC:-21600}" --poll "${POLL_SEC:-30}"
}

# 승인 요청 메일 발송(답장 안내) → IMAP 폴링. stdout에 y|n, rc 그대로 전파.
# 계약은 remote_ask와 호환(stdout=답, rc 0/3). 추가로 4/5=IMAP 불가(호출부가 폴백).
remote_approve_email(){  # <id> <bodyfile>
  local id="$1" bodyfile="$2"
  local token="OLY-${id}"
  local from="${APPROVE_FROM:-${SMTP_SENDER:-}}"
  local nb; nb="$(mktemp)"
  { printf '━━ 응답 방법 ━━\n'
    printf '▶ 이 메일에 그대로 「답장(Reply)」 하세요. 다른 채널(GitHub 등) 아님.\n'
    printf '▶ 답장 본문 첫 줄에 y (승인) 또는 n (보류) 만 적으면 됩니다.\n'
    printf '   · 제목은 바꾸지 마세요(답장이면 자동 유지 — ‹%s› 토큰으로 매칭)\n' "$token"
    printf '   · 등록된 주소(%s)에서 보낸 답장만 인정됩니다.\n' "${from:-발신 계정}"
    printf '━━━━━━━━━━━━\n\n'
    printf '전체 개발 완료 + verify green. 아래 내용 확인 후 머지 승인 여부를 답장해 주세요.\n\n'
    cat "$bodyfile"
  } > "$nb"
  # 링크 인자 없이 발송 = GitHub 버튼 없는 순수 답장 안내 메일. best-effort.
  remote_notify "[올림푸스] 최종 머지 승인 ‹${token}›" "$(cat "$nb")" || \
    echo "⚠️ 승인 요청 메일 발송 실패(id=$id) — IMAP 폴링은 계속" >&2
  rm -f "$nb"
  local ans rc
  ans="$(_inbox_await "$token" "$from")"; rc=$?
  [ -n "$ans" ] && printf '%s' "$ans"
  return "$rc"
}
