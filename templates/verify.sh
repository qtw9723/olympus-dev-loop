#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# 범용 게이트(심판) 템플릿 — 새 프로젝트 생성 시 olympus이 자동 복사한다.
# greenfield 관용형: 있는 스택만 검사, 없으면 통과(스캐폴딩이 진행될수록 게이트가 켜짐).
#
# 🚫 이 파일은 "심판"이다. Builder(생성자)는 절대 수정하지 말 것.
#    환경과 안 맞거나 깨졌으면 고치지 말고 ask-planner로 보고하라(사람/기획자 권한).
# ──────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")"; fail=0

# ── Python 백엔드 (backend/) ──
if [ -d backend ]; then
  echo "== backend =="
  (
    cd backend
    if [ ! -d .venv ]; then
      PY=""
      for c in python3.13 python3.12 python3.11; do
        command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
      done
      if [ -z "$PY" ] && command -v python3 >/dev/null 2>&1; then
        v="$(python3 -c 'import sys;print(sys.version_info[0]*100+sys.version_info[1])' 2>/dev/null || echo 0)"
        [ "${v:-0}" -ge 311 ] && PY=python3
      fi
      [ -n "$PY" ] || { echo "❌ Python 3.11+ 필요. 설치 후 재시도 — 잘못된 인터프리터로 거짓 통과/실패 금지."; exit 1; }
      "$PY" -m venv .venv
    fi
    # shellcheck disable=SC1091
    source .venv/bin/activate
    if ! python -m ruff --version >/dev/null 2>&1; then
      [ -f requirements.txt ] && pip install -q -r requirements.txt
    fi
    python -m ruff check . \
      && { [ -d tests ] && python -m pytest -q || echo "(no backend tests yet)"; }
  ) || fail=1
fi

# ── Node/TS 프론트엔드 (frontend/) ──
if [ -d frontend ]; then
  echo "== frontend =="
  (
    cd frontend
    [ -d node_modules ] || npm ci 2>/dev/null || npm install
    npm run lint && npm run build
  ) || fail=1
fi

# ── 루트에 단일 node 프로젝트인 경우 (frontend/backend 없이 package.json) ──
if [ ! -d backend ] && [ ! -d frontend ] && [ -f package.json ]; then
  echo "== node (root) =="
  ( [ -d node_modules ] || npm ci 2>/dev/null || npm install; npm run verify 2>/dev/null || { npm run lint && npm run build; } ) || fail=1
fi

[ -d backend ] || [ -d frontend ] || [ -f package.json ] || echo "(스캐폴딩 전 — 통과)"
exit $fail
