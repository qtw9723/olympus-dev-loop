#!/usr/bin/env bash
# 새 작업(새 spec) 시작용 상태 초기화. spec/ 와 roles/·config.sh 는 보존,
# 해당 프로젝트의 state/<프로젝트>/ 만 비운다. 실행 로그(runs/)도 보존.
# 사용: bash reset.sh <프로젝트>
set -euo pipefail
PROJ="${1:-}"
[ -n "$PROJ" ] || { echo "사용법: bash reset.sh <프로젝트>  (state/<프로젝트>/ 만 초기화)"; exit 2; }
P="$(cd "$(dirname "$0")" && pwd)/state/$PROJ"
mkdir -p "$P"

cat > "$P/handoff.json" <<'EOF'
{
  "turn": "metis",
  "round": 0,
  "status": "pending",
  "max_rounds": 6,
  "task": "",
  "note": "reset됨. spec/ 채운 뒤 run.sh 실행 → 메티스가 분석·분해부터 시작."
}
EOF

: > "$P/requirements.md"; cat > "$P/requirements.md" <<'EOF'
# 요구사항 분석서 (메티스 소유 — 비어 있으면 아직 분석 전)
EOF

cat > "$P/backlog.md" <<'EOF'
# 백로그 (Phase 0 산출물 — 비어 있으면 아직 분해 전)
EOF

cat > "$P/task.md" <<'EOF'
# 현재 작업 (메티스가 채움 — 비어 있으면 아직 없음)
EOF

for f in critic-feedback ask-planner findings open-questions questions decisions human-answers builder-notes deploy progress; do
  printf '<!-- 초기 상태: 비어 있음 -->\n' > "$P/$f.md"
done

printf '# verify 실행 기록(런타임).\n' > "$P/verify.txt"
rm -f "$P/base_branch" "$P/work_branch"   # 이전 실행의 브랜치 기록 제거

echo "✅ state/$PROJ 초기화 완료. 이제 spec/$PROJ/ 에 기획 문서를 넣고 'bash run.sh' 실행."
