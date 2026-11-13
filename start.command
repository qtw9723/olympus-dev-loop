#!/usr/bin/env bash
# start.command — 올림푸스 원클릭 시작 (Finder 더블클릭 / Dock / 터미널 alias)
# UI 서버 기동 → 브라우저 열기 → 큐 상시 감시(웹 UI에서 등록하면 자동 실행). 중지: 이 창에서 Ctrl+C.
cd "$(dirname "$0")" || exit 1
printf '\n  🏛  O L Y M P U S — 기획서를 넣으면 신들이 개발한다\n\n'
PORT="${OLYMPUS_UI_PORT:-8765}"
bash ui.sh autostart "$PORT" && command -v open >/dev/null 2>&1 && open "http://127.0.0.1:$PORT"
exec bash queue.sh work --watch
