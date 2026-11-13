#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/spec/ok" "$PIPELINE_DIR/spec/vfail" "$PIPELINE_DIR/spec/blocked"
cp "$ROOT/queue.sh" "$PIPELINE_DIR/queue.sh"
: > "$PIPELINE_DIR/config.sh"
# 스텁 run.sh: 프로젝트별 지정된 rc로 종료. blocked는 questions.md도 남김.
cat > "$PIPELINE_DIR/run.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$PIPELINE_DIR/state/$PROJECT"
case "$PROJECT" in
  ok) exit 0 ;;
  vfail) exit 1 ;;
  blocked) printf '어떤 DB를 쓸까요?\n' > "$PIPELINE_DIR/state/$PROJECT/questions.md"; exit 2 ;;
esac
EOF
QUEUE_LIB=1 . "$PIPELINE_DIR/queue.sh"
queue_add ok >/dev/null; queue_add vfail >/dev/null; queue_add blocked lite >/dev/null
NOTIFY_MILESTONES=0 OLYMPUS_UI=0 OLYMPUS_SETUP=0 queue_work >/dev/null 2>&1

assert_eq "done"   "$(queue_get '.items[0].status')" "rc0 → done"
assert_eq "green"  "$(queue_get '.items[0].result')" "result=green"
assert_eq "failed" "$(queue_get '.items[1].status')" "rc1 → failed"
assert_eq "failed:verify" "$(queue_get '.items[1].result')" "result=failed:verify"
assert_eq "paused" "$(queue_get '.items[2].status')" "rc2 → paused"
assert_eq "blocker" "$(queue_get '.items[2].paused_reason')" "reason=blocker"
assert_contains "$(queue_get '.items[2].result')" "어떤 DB" "블로커 질문 한줄 미러"
assert_eq "null" "$(queue_get '.worker')" "드레인 후 worker=null"

echo; echo "queue_work: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
