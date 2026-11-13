#!/usr/bin/env bash
# queue.sh work --watch — 상시 대기: 빈 큐에서 안 죽고, 나중에 등록된 항목을 집어간다
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"
cleanup(){ [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/spec/ok"
cp "$ROOT/queue.sh" "$PIPELINE_DIR/queue.sh"
: > "$PIPELINE_DIR/config.sh"
cat > "$PIPELINE_DIR/run.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

QUEUE_LIB=1 . "$PIPELINE_DIR/queue.sh"

# 1) 빈 큐로 감시 시작 → 종료하지 않고 대기
OLYMPUS_UI=0 OLYMPUS_SETUP=0 NOTIFY_MILESTONES=0 bash "$PIPELINE_DIR/queue.sh" work --watch 1 >/dev/null 2>&1 &
WPID=$!
sleep 2
kill -0 "$WPID" 2>/dev/null && ALIVE=1 || ALIVE=0
assert_eq "1" "$ALIVE" "빈 큐에서도 계속 대기"

# 2) 감시 중 등록 → 폴링이 집어가 처리(done)
queue_add ok >/dev/null
ID="$(queue_get '.items[0].id')"
STATUS=""
for _ in $(seq 1 20); do
  STATUS="$(queue_item_get "$ID" '.status')"
  [ "$STATUS" = "done" ] && break
  sleep 0.5
done
assert_eq "done" "$STATUS" "감시 중 등록된 항목 처리"

# 3) 처리 후에도 감시는 살아 있다(다음 등록 대비)
kill -0 "$WPID" 2>/dev/null && ALIVE2=1 || ALIVE2=0
assert_eq "1" "$ALIVE2" "처리 후에도 감시 유지"

kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

echo; echo "queue_watch: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
