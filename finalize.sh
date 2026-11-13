# 올림푸스 완료 정리 — run.sh가 source. 프로젝트가 승인·머지로 끝나면 호출.
# 완료된 기획서를 spec/_done/<프로젝트>-<시각>/ 로 아카이브(완료 기록 스냅샷 포함)하고,
# state/를 초기화해 새 기획서가 들어오면 바로 시작 가능한 상태로 만든다.
# 전역(run.sh가 세팅): PIPELINE_DIR, PROJECT, TARGET_REPO, BASE_BRANCH, B.

finalize_project () {
  local project="${1:-${PROJECT:-}}"
  [ -n "$project" ] || { echo "ℹ️ 정리할 프로젝트명 없음 — 스킵."; return 0; }
  local pdir="$PIPELINE_DIR/spec/$project"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local dest="$PIPELINE_DIR/spec/_done/${project}-${stamp}"
  mkdir -p "$dest"

  # 완료 기록 + state 스냅샷(무엇을 왜 했는지 추적용)
  {
    echo "project: $project"
    echo "completed_at: $(date +%Y-%m-%dT%H:%M:%S)"
    echo "target_repo: ${TARGET_REPO:-}"
    echo "base_branch: ${BASE_BRANCH:-}"
    echo "work_branch: ${B:-}"
  } > "$dest/COMPLETED.txt"
  local s
  for s in requirements decisions backlog open-questions; do
    [ -f "${STATE_DIR:-$PIPELINE_DIR/state}/$s.md" ] && cp "${STATE_DIR:-$PIPELINE_DIR/state}/$s.md" "$dest/$s.md"
  done

  # 원본 기획서 이동(있으면). _done은 '_' 접두사라 run.sh 자동선택에서 제외됨.
  if [ -d "$pdir" ]; then
    mv "$pdir" "$dest/spec"
    echo "📦 아카이브: spec/$project → spec/_done/${project}-${stamp}/"
  else
    echo "ℹ️ spec/$project 없음 — 기록만 남김: spec/_done/${project}-${stamp}/"
  fi

  # state 초기화 → 새 기획 대기 상태
  if bash "$PIPELINE_DIR/reset.sh" "$project" >/dev/null 2>&1; then
    echo "🧹 state 초기화 완료 — 새 기획서(spec/<이름>/)를 넣으면 바로 시작."
  else
    echo "⚠️ state 초기화 실패 — 수동으로 'bash reset.sh' 실행 필요."
    return 1
  fi
}
