#!/usr/bin/env bash
# 게이트(심판): TARGET_REPO에서 VERIFY_CMD 실행 → 결과를 이 pipeline의 state/verify.txt에 기록.
# 언어/프로젝트가 바뀌면 config.sh의 VERIFY_CMD만 교체(어댑터).
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$PIPELINE_DIR/config.sh"
OUT="${STATE_DIR:-$PIPELINE_DIR/state}/verify.txt"
mkdir -p "${STATE_DIR:-$PIPELINE_DIR/state}"

# ── 재귀/오설정 가드 (fork 폭탄 방지) ──
# TARGET_REPO가 비면 `cd ""`가 현재 디렉토리(파이프라인)에 머물러, VERIFY_CMD 기본값
# "bash verify.sh"가 이 스크립트를 재귀 실행 → fork 폭탄. 방어적으로 즉시 중단한다.
if [ -z "${TARGET_REPO:-}" ]; then
  { echo "# verify ABORTED: TARGET_REPO 비어 있음 (run.sh가 export 안 했을 가능성)"; echo "VERIFY_EXIT=2"; } | tee "$OUT"
  exit 2
fi
if [ ! -d "$TARGET_REPO" ]; then
  { echo "# verify ABORTED: TARGET_REPO 디렉토리 없음: $TARGET_REPO"; echo "VERIFY_EXIT=2"; } | tee "$OUT"
  exit 2
fi
# 자기참조: 게이트가 게이트 자신을 verify 명령으로 부르는 극단적 오설정도 차단.
if [ "$TARGET_REPO/verify.sh" -ef "$0" ] 2>/dev/null && printf '%s' "${VERIFY_CMD:-}" | grep -q 'verify\.sh'; then
  { echo "# verify ABORTED: VERIFY_CMD가 게이트 자신을 재귀 호출 (TARGET_REPO=$TARGET_REPO)"; echo "VERIFY_EXIT=2"; } | tee "$OUT"
  exit 2
fi

{
  echo "# verify @ $(date -u +%FT%TZ)  (target: $TARGET_REPO)"
  ( cd "$TARGET_REPO" && eval "$VERIFY_CMD" )
} 2>&1 | tee "$OUT"
CODE=${PIPESTATUS[0]}
echo "VERIFY_EXIT=$CODE" | tee -a "$OUT"
exit "$CODE"
