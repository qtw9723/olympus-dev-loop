# 올림푸스 배포 단계 — run.sh가 source. 머지 완료 후 호출.
# 배포 규약 우선순위: DEPLOY_CMD(env/config) → state/deploy.md(메티스가 spec에서 추출).
# 규약이 있으면 그대로 실행, 전무하면 10을 반환해 호출부가 사용자에게 묻게 한다.
# 전역(run.sh): PIPELINE_DIR, TARGET_REPO, DEPLOY_CMD.

# state/deploy.md에서 실행할 배포 명령만 추출(주석/빈 줄 제외).
_deploy_cmd_from_state () {
  local f="${STATE_DIR:-$PIPELINE_DIR/state}/deploy.md"
  [ -f "$f" ] || return 0
  # '#' 주석, '<!-- ... -->' 주석, 빈 줄 제거 → 남은 게 명령.
  grep -vE '^[[:space:]]*(#|<!--|-->|$)' "$f" 2>/dev/null
}

# 배포 실행. 명령 exit code 반환. 규약 전무 시 10 반환(배포 안 함).
deploy_project () {
  local cmd="${DEPLOY_CMD:-}"
  [ -n "$cmd" ] || cmd="$(_deploy_cmd_from_state)"
  if [ -z "${cmd//[[:space:]]/}" ]; then
    return 10   # 배포 규약 없음 → 호출부가 사용자에게 질문
  fi
  echo "🚀 배포 실행:"; printf '%s\n' "$cmd" | sed 's/^/    /'
  ( cd "$TARGET_REPO" 2>/dev/null && eval "$cmd" )
  local rc=$?
  [ "$rc" -eq 0 ] && echo "✅ 배포 완료" || echo "⚠️ 배포 명령 실패(exit $rc)"
  return "$rc"
}
