#!/usr/bin/env bash
# setup.sh — 로컬 세팅 마이그레이션 (풀 받으면 다음 실행 때 자동 적용)
#
# 저장소가 요구하는 세팅 버전(SETUP_VERSION, git 추적)과 이 기기에 적용된 버전
# (state/setup.version, git 미추적)을 비교해 모자란 단계만 순서대로 적용한다.
# run.sh/queue.sh work 시작 시 자동 호출(멱등, OLYMPUS_SETUP=0 으로 끔). 직접: bash setup.sh
#
# 새 세팅 추가법: SETUP_VERSION을 1 올리고 setup_step_<N> 함수를 추가한다.
#   - 각 단계는 멱등이어야 한다(이미 되어 있으면 조용히 통과).
#   - 플랫폼 전용 동작은 uname 가드([ "$(uname)" = Darwin ])를 걸 것(Windows=Git Bash/WSL 가정).
#   - 단계 실패 시 마커가 멈춰 다음 실행 때 그 단계부터 재시도된다.
SETUP_VERSION=1
SETUP_DIR="${PIPELINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SETUP_MARKER="$SETUP_DIR/state/setup.version"

_setup_rcfile(){   # 이 기기의 셸 rc 파일 (mac=zsh, Git Bash/WSL=bash)
  case "${SHELL:-}" in */zsh) echo "$HOME/.zshrc" ;; *) echo "$HOME/.bashrc" ;; esac
}

setup_step_1(){   # 터미널 alias 'olympus' — 원클릭 시작(UI+브라우저+큐 감시)
  local rc; rc="$(_setup_rcfile)"
  grep -qs "alias olympus=" "$rc" && return 0
  { echo ""; echo "# 올림푸스 원클릭 시작 (olympus setup v1)"
    echo "alias olympus='bash $SETUP_DIR/start.command'"; } >> "$rc" || return 1
  echo "🔧 setup v1: alias olympus 추가 → $rc (새 터미널부터 적용)"
}

setup_apply(){
  local cur=0
  [ -f "$SETUP_MARKER" ] && cur="$(cat "$SETUP_MARKER" 2>/dev/null)"
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  [ "$cur" -ge "$SETUP_VERSION" ] && return 0
  mkdir -p "$SETUP_DIR/state"
  local v=$((cur+1))
  while [ "$v" -le "$SETUP_VERSION" ]; do
    if ! "setup_step_$v"; then
      echo "⚠️ 로컬 세팅 v$v 적용 실패 — 다음 실행 때 재시도 (수동: bash setup.sh)" >&2
      return 1
    fi
    echo "$v" > "$SETUP_MARKER"
    v=$((v+1))
  done
  echo "✅ 로컬 세팅 v$SETUP_VERSION 적용 완료"
}

# 직접 실행 지원: bash setup.sh
if [ "${BASH_SOURCE[0]}" = "$0" ]; then setup_apply; fi
