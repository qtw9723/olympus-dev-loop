#!/usr/bin/env bash
# ui.sh — 큐 로컬 웹 UI 런처 (127.0.0.1 전용, 기본 포트 8765)
# 사용: bash ui.sh [포트]              # 포그라운드 실행 (Ctrl+C로 중지)
#       bash ui.sh autostart [포트]    # 백그라운드 멱등 기동 — 이미 떠 있으면 no-op (run.sh/queue.sh가 호출)
#       bash ui.sh stop               # autostart로 띄운 서버 종료
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT="${PIPELINE_DIR:-$DIR}/state"
UI_PID_FILE="$STATE_ROOT/ui.pid"

case "${1:-}" in
  autostart)
    PORT="${2:-8765}"
    if curl -sf -m 2 "http://127.0.0.1:$PORT/api/queue" >/dev/null 2>&1; then
      echo "🌐 큐 UI 이미 실행 중 — http://127.0.0.1:$PORT"
      exit 0
    fi
    mkdir -p "$STATE_ROOT"
    nohup python3 "$DIR/ui/server.py" --port "$PORT" >> "$STATE_ROOT/ui.log" 2>&1 &
    echo $! > "$UI_PID_FILE"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -sf -m 1 "http://127.0.0.1:$PORT/api/queue" >/dev/null 2>&1; then
        echo "🌐 큐 UI 시작 — http://127.0.0.1:$PORT"
        exit 0
      fi
      sleep 0.3
    done
    echo "⚠️ 큐 UI 기동 실패 — $STATE_ROOT/ui.log 확인" >&2
    exit 1
    ;;
  stop)
    if [ -f "$UI_PID_FILE" ] && kill "$(cat "$UI_PID_FILE")" 2>/dev/null; then
      echo "🛑 큐 UI 종료 (pid $(cat "$UI_PID_FILE"))"
    else
      echo "ℹ️ 실행 중인 큐 UI 없음(ui.pid 기준)"
    fi
    rm -f "$UI_PID_FILE"
    ;;
  *)
    exec python3 "$DIR/ui/server.py" ${1:+--port "$1"}
    ;;
esac
