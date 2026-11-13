#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 가짜 PIPELINE_DIR: 실제 reset.sh/finalize.sh 복사 + state + spec/proj
export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/state/proj/runs" "$PIPELINE_DIR/spec/proj"
export STATE_DIR="$PIPELINE_DIR/state/proj"
cp "$ROOT/reset.sh" "$PIPELINE_DIR/reset.sh"
cp "$ROOT/finalize.sh" "$PIPELINE_DIR/finalize.sh"
printf '# 기획\n태그 정규화\n' > "$PIPELINE_DIR/spec/proj/기획.md"
# 완료 시점의 state(내용 채워진 상태)
printf '# 요구사항\n- 구분자=하이픈\n' > "$STATE_DIR/requirements.md"
printf '# 결정\n- 하이픈 확정\n'      > "$STATE_DIR/decisions.md"
printf '# 백로그\n## [done] T1\n'      > "$STATE_DIR/backlog.md"
printf '답: 하이픈\n'                   > "$STATE_DIR/human-answers.md"
printf '# oq\n'                         > "$STATE_DIR/open-questions.md"

. "$PIPELINE_DIR/finalize.sh"
export PROJECT=proj TARGET_REPO=/x/proj BASE_BRANCH=main B=olympus/proj-1
finalize_project >/dev/null

# 1) 원본 spec 폴더가 활성 위치에서 사라짐
[ ! -d "$PIPELINE_DIR/spec/proj" ] && pass "원본 spec/proj 이동됨" || fail "원본 spec/proj 아직 있음"
# 2) _done 아카이브에 spec + COMPLETED.txt + 스냅샷 존재
ARCH=$(find "$PIPELINE_DIR/spec/_done" -maxdepth 1 -type d -name 'proj-*' | head -1)
[ -n "$ARCH" ] && pass "_done 아카이브 폴더 생성" || fail "_done 아카이브 없음"
[ -f "$ARCH/spec/기획.md" ] && pass "기획서 아카이브됨" || fail "기획서 아카이브 안 됨"
[ -f "$ARCH/COMPLETED.txt" ] && pass "COMPLETED.txt 생성" || fail "COMPLETED.txt 없음"
assert_contains "$(cat "$ARCH/COMPLETED.txt")" "work_branch: olympus/proj-1" "완료기록에 작업브랜치"
[ -f "$ARCH/decisions.md" ] && pass "decisions 스냅샷" || fail "decisions 스냅샷 없음"
# 3) _done은 run.sh 자동선택(find ! -name '_*')에서 제외됨
SEL=$(find "$PIPELINE_DIR/spec" -mindepth 1 -maxdepth 1 -type d ! -name '_*' | wc -l | tr -d ' ')
assert_eq "0" "$SEL" "활성 spec 폴더 0개(=_done만 남음, 새 기획 대기)"
# 4) state 초기화됨(requirements 비고, human-answers도 초기화)
REQ=$(cat "$STATE_DIR/requirements.md")
case "$REQ" in *"구분자=하이픈"*) fail "state requirements 초기화 안 됨" ;; *) pass "state requirements 초기화됨" ;; esac
HA=$(cat "$STATE_DIR/human-answers.md")
case "$HA" in *"답: 하이픈"*) fail "human-answers 초기화 안 됨" ;; *) pass "human-answers 초기화됨(잔이슈 수정)" ;; esac

[ "${TESTS_FAIL:-0}" -eq 0 ]
