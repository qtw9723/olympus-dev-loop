#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"; . "$ROOT/gitops.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# fixture: main에 초기 커밋 + 작업 브랜치
export TARGET_REPO="$TMP/repo"
mkdir -p "$TARGET_REPO"
( cd "$TARGET_REPO" && git init -q -b main \
  && printf 'v1\n' > f.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm init )
export BASE_BRANCH=main
export B="olympus/test-branch"
export PROJECT=repo
( cd "$TARGET_REPO" && git switch -c "$B" -q )

# 1) 빌더가 파일 수정(uncommitted) → commit_task가 작업 브랜치에 커밋
printf 'v2\n' > "$TARGET_REPO/f.txt"
commit_task "T1 변경"
CNT_ON_B=$( cd "$TARGET_REPO" && git rev-list --count main.."$B" )
assert_eq "1" "$CNT_ON_B" "commit_task가 작업 브랜치에 1커밋 생성"
CLEAN=$( cd "$TARGET_REPO" && git status --porcelain )
assert_eq "" "$CLEAN" "커밋 후 워킹트리 클린"

# 2) 변경 없을 때 commit_task는 커밋 안 함(스킵)
commit_task "빈 변경"
CNT2=$( cd "$TARGET_REPO" && git rev-list --count main.."$B" )
assert_eq "1" "$CNT2" "변경 없으면 추가 커밋 안 함"

# 3) merge_work_branch: 작업 브랜치를 main에 머지
merge_work_branch >/dev/null; RC=$?
assert_eq "0" "$RC" "머지 성공 반환 0"
NOWBR=$( cd "$TARGET_REPO" && git rev-parse --abbrev-ref HEAD )
assert_eq "main" "$NOWBR" "머지 후 main 체크아웃"
MERGED=$( cd "$TARGET_REPO" && cat f.txt )
assert_eq "v2" "$MERGED" "main에 작업 내용 반영됨"

# 4) 충돌 시 abort하고 실패 반환, 워킹트리 보존
( cd "$TARGET_REPO" && git switch -c olympus/conflict -q && printf 'branchX\n' > f.txt \
  && git -c user.email=t@t -c user.name=t commit -qam x \
  && git switch main -q && printf 'mainY\n' > f.txt \
  && git -c user.email=t@t -c user.name=t commit -qam y )
B2="olympus/conflict"; ( export B="$B2"; merge_work_branch >/dev/null 2>&1; echo $? > "$TMP/rc2" )
assert_eq "1" "$(cat "$TMP/rc2")" "충돌 시 실패 반환 1"
NOMERGE=$( cd "$TARGET_REPO" && git status --porcelain )
assert_eq "" "$NOMERGE" "충돌 abort 후 워킹트리 클린(잔여 없음)"

# 5) B/BASE_BRANCH 없으면 머지 생략하고 0
( unset B; merge_work_branch >/dev/null; echo $? > "$TMP/rc3" )
assert_eq "0" "$(cat "$TMP/rc3")" "작업 브랜치 없으면 머지 생략(0)"

[ "${TESTS_FAIL:-0}" -eq 0 ]
