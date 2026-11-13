# 올림푸스 git 흐름 — run.sh가 source. 작업 커밋 + 승인 후 머지.
# 전역(run.sh가 세팅): TARGET_REPO, B(작업 브랜치), BASE_BRANCH(기준), PROJECT.
# 커밋 identity는 로컬 override로 고정(전역 git config 오염 방지).

# 현재 TARGET_REPO 워킹트리 변경을 현재 브랜치에 커밋한다.
# 변경 없으면 조용히 스킵(0). git repo 아니면 스킵(0).
commit_task () {
  local msg="${1:-작업 반영}"
  ( cd "$TARGET_REPO" 2>/dev/null || exit 0
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    git add -A
    git diff --cached --quiet 2>/dev/null && exit 0   # 변경 없음
    git -c user.email=olympus@local -c user.name=olympus commit -qm "olympus: $msg" >/dev/null 2>&1 )
  return 0
}

# 작업 브랜치 B를 기준 브랜치 BASE_BRANCH에 --no-ff 머지한다.
# 성공 0 / 실패(전환·충돌) 1. 충돌 시 merge --abort로 되돌리고 B 유지.
# B 또는 BASE_BRANCH가 없으면(greenfield 등) 머지할 게 없다고 보고 0.
merge_work_branch () {
  if [ -z "${B:-}" ] || [ -z "${BASE_BRANCH:-}" ]; then
    echo "ℹ️ 작업 브랜치 없음 — 머지 생략(변경은 이미 기준 브랜치에 있음)."
    return 0
  fi
  ( cd "$TARGET_REPO" 2>/dev/null || { echo "⛔ TARGET_REPO 접근 불가"; exit 1; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "⛔ git repo 아님"; exit 1; }
    if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$B" ] && git diff --quiet && git diff --cached --quiet; then :; fi
    git switch "$BASE_BRANCH" 2>/dev/null || git checkout "$BASE_BRANCH" 2>/dev/null \
      || { echo "⛔ 기준 브랜치($BASE_BRANCH) 전환 실패"; exit 1; }
    if git merge --no-ff "$B" -m "merge: olympus ${PROJECT:-작업} ($B)" >/dev/null 2>&1; then
      echo "✅ 머지 완료: $B → $BASE_BRANCH"
      rm -f "${STATE_DIR:-/nonexistent}/base_branch" "${STATE_DIR:-/nonexistent}/work_branch" 2>/dev/null
      exit 0
    else
      git merge --abort 2>/dev/null
      echo "⛔ 머지 충돌 — 중단(작업 브랜치 $B 유지, 수동 처리 필요)"
      exit 1
    fi )
}
