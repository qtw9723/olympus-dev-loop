#!/usr/bin/env bash
# Olympus 오프라인 데모 — API 키·네트워크 없이 run.sh 전체 루프를 재현한다.
# ⚠️ 실운영이 아니다: 역할 세션(claude)은 demo/bin/claude의 스크립트 응답으로 대체된다.
#    run.sh의 루프·verify 게이트·핸드오프·사람 에스컬레이션 로직은 실제 코드 그대로 실행된다.
#
# 시나리오
#   1) 기획자가 작업을 분해 → 구현 역할이 실패하는 테스트를 verify.sh 수정으로 가린다
#   2) run.sh 게이트는 green이라고 보고하지만, 비평 역할이 diff에서 심판 파일 변경을 적발 → 사람 에스컬레이션
#   3) 사람이 verify.sh를 원복하고 재개 → 구현 수정 → 진짜 verify green → 비평 green → 승인·머지
#
# 사용: bash demo/run-demo.sh        (전부 임시 폴더에서 실행, 이 저장소는 건드리지 않는다)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq가 필요합니다."; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3가 필요합니다."; exit 2; }

W="$(mktemp -d)"; [ "${DEMO_KEEP:-0}" = 1 ] || trap 'rm -rf "$W"' EXIT
OLY="$W/olympus"; PROJ="slugify-demo"; TARGET="$W/projects/$PROJ"
mkdir -p "$OLY" "$W/projects"
( cd "$ROOT" && tar --exclude=./.git --exclude=./state --exclude='./spec/*' -cf - . ) | ( cd "$OLY" && tar -xf - )
mkdir -p "$OLY/spec/$PROJ" && cp "$ROOT/demo/spec/$PROJ/"*.md "$OLY/spec/$PROJ/"

# 대상 repo: 기존 코드가 있는 상태(brownfield)로 만들어 작업 브랜치·머지까지 보여준다
mkdir -p "$TARGET" && cd "$TARGET"
git init -q -b main
printf '# slugify-demo\n' > README.md
cat > verify.sh <<'V'
#!/usr/bin/env bash
# 심판: 단위 테스트가 통과해야 green. Builder는 수정 금지.
set -uo pipefail
cd "$(dirname "$0")"
python3 -m unittest discover -s . -p 'test_*.py' -v
V
git add -A && git -c user.email=demo@local -c user.name=demo commit -qm "init: judge + readme"
JUDGE_SHA="$(git rev-parse HEAD)"

export PATH="$ROOT/demo/bin:$PATH"
export PROJECTS_DIR="$W/projects" PROJECT="$PROJ" TARGET_REPO="$TARGET" VERIFY_CMD="bash verify.sh"
export OLYMPUS_SETUP=0 OLYMPUS_UI=0 USAGE_TRACK=0 TOKEN_WAIT=0
export AUTO_APPROVE=1 AUTO_MERGE=1 DEPLOY_ON_DONE=0 ARCHIVE_ON_DONE=0 MAX_ROUNDS=4
export HOME="$W/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@local GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@local   # 머지 커밋용(임시 HOME엔 git 설정이 없다)

step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
FAIL=0
check() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; FAIL=1; fi; }

step "1/3 첫 실행 — 구현 역할이 심판 파일을 건드리는 시나리오"
bash "$OLY/run.sh" > "$W/run1.log" 2>&1; RC1=$?
cat "$W/run1.log"
check "run.sh가 사람 에스컬레이션으로 중단(exit 3)" '[ "$RC1" = 3 ]'
check "게이트는 green으로 보고됐다(약화된 verify)" 'grep -q "^VERIFY_EXIT=0" "$OLY/state/$PROJ/verify.txt"'
check "비평 피드백에 ⚠️심판변경 기록" 'grep -q "심판변경" "$OLY/state/$PROJ/critic-feedback.md"'

step "2/3 사람 개입 — verify.sh 원복 후 재개"
( cd "$TARGET" && git checkout -- verify.sh )
jq '.turn="builder" | .status="reviewing"' "$OLY/state/$PROJ/handoff.json" > "$W/h.json" && mv "$W/h.json" "$OLY/state/$PROJ/handoff.json"
echo "  사람: git checkout -- verify.sh, handoff turn=builder"
bash "$OLY/run.sh" > "$W/run2.log" 2>&1; RC2=$?
cat "$W/run2.log"

step "3/3 결과 검증"
check "재개 실행이 정상 종료(exit 0)" '[ "$RC2" = 0 ]'
check "백로그 전부 완료(all_done)" 'grep -q "백로그 전부 완료" "$W/run2.log"'
check "최종 verify green" '(cd "$TARGET" && bash verify.sh >/dev/null 2>&1)'
check "심판 파일이 최초 커밋과 동일" '(cd "$TARGET" && git diff --quiet "$JUDGE_SHA" -- verify.sh)'
check "작업 브랜치가 main에 머지됨" '(cd "$TARGET" && git log --oneline main | grep -q "olympus: slugify")'

if [ -n "${DEMO_TRANSCRIPT:-}" ]; then { echo "===== run 1 (exit $RC1) ====="; cat "$W/run1.log"; echo; echo "===== human: git checkout -- verify.sh ====="; echo; echo "===== run 2 (exit $RC2) ====="; cat "$W/run2.log"; } > "$DEMO_TRANSCRIPT"; fi
echo; [ "$FAIL" = 0 ] && echo "데모 통과 ✅ (실운영 아님: 스크립트된 에이전트 응답)" || echo "데모 실패 ❌"
exit "$FAIL"
