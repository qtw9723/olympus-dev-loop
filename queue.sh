#!/usr/bin/env bash
# queue.sh — 멀티 프로젝트 큐. state/queue.json이 단일 진실(UI 계약 v1).
# CLI:  bash queue.sh add <프로젝트> [--mode lite|full] | list | work | migrate <프로젝트>
# 라이브러리: QUEUE_LIB=1 . queue.sh  (run.sh 체크포인트/미러용 — CLI 미실행)
#
# 필드 소유권(UI와 워커가 같은 필드를 다투지 않게):
#   UI  → queued/paused 항목의 추가·삭제·배열 순서·mode 변경, paused→queued 되돌리기,
#         running 항목엔 request("pause"|"cancel")만.
#   워커 → status/progress/mode_resolved/result/paused_reason/타임스탬프/worker 블록.
# 락: macOS엔 flock이 없어 mkdir 락(원자적) + pid 스테일 회수. 쓰기는 tmp→mv(원자적).
PIPELINE_DIR="${PIPELINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
QUEUE_ROOT="$PIPELINE_DIR/state"
QUEUE_FILE="$QUEUE_ROOT/queue.json"
QUEUE_LOCK="$QUEUE_ROOT/queue.lock"
QUEUE_LOCK_MAX_TRIES="${QUEUE_LOCK_MAX_TRIES:-100}"   # 0.1s 간격 → 기본 최대 10초

_q_now(){ date +%FT%T%z; }

queue_lock(){
  local i=0 lp
  mkdir -p "$QUEUE_ROOT"
  while ! mkdir "$QUEUE_LOCK" 2>/dev/null; do
    lp="$(cat "$QUEUE_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null; then rm -rf "$QUEUE_LOCK"; continue; fi
    i=$((i+1)); [ "$i" -ge "$QUEUE_LOCK_MAX_TRIES" ] && { echo "❌ queue.lock 획득 실패(점유 pid=${lp:-?})" >&2; return 1; }
    sleep 0.1
  done
  echo $$ > "$QUEUE_LOCK/pid"
}
queue_unlock(){ rm -rf "$QUEUE_LOCK"; }

queue_init(){ [ -f "$QUEUE_FILE" ] || { mkdir -p "$QUEUE_ROOT"; printf '{"version":1,"worker":null,"items":[]}\n' > "$QUEUE_FILE"; }; }

# 원자적 갱신: $1=jq 필터. 락 → tmp → mv.
queue_edit(){
  queue_lock || return 1
  queue_init
  local tmp; tmp="$(mktemp)"
  if jq "$1" "$QUEUE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$QUEUE_FILE"; queue_unlock
  else
    rm -f "$tmp"; queue_unlock; echo "❌ queue.json 갱신 실패: $1" >&2; return 1
  fi
}
queue_get(){ queue_init; jq -r "$1" "$QUEUE_FILE" 2>/dev/null; }
queue_item_get(){ queue_init; jq -r --arg id "$1" ".items[]|select(.id==\$id)|$2" "$QUEUE_FILE" 2>/dev/null; }
queue_item_set(){ queue_edit "(.items[]|select(.id==\"$1\")) |= ($2)"; }
queue_heartbeat(){ queue_edit ".worker.heartbeat_at=\"$(_q_now)\""; }

# 구(단일 state) 레이아웃 가드/이행
queue_guard_legacy(){
  if [ -f "$QUEUE_ROOT/handoff.json" ]; then
    echo "⚠️ 구 state 레이아웃 감지 — 먼저 실행: bash queue.sh migrate <프로젝트명>" >&2
    return 2
  fi
}
queue_migrate(){
  local p="${1:?사용법: queue_migrate <프로젝트>}"
  [ -f "$QUEUE_ROOT/handoff.json" ] || { echo "ℹ️ 구 레이아웃 아님 — 마이그레이션 불필요"; return 0; }
  mkdir -p "$QUEUE_ROOT/$p"
  local f
  for f in "$QUEUE_ROOT"/*.md "$QUEUE_ROOT"/handoff.json "$QUEUE_ROOT"/usage.tsv "$QUEUE_ROOT"/verify.txt; do
    [ -f "$f" ] && mv "$f" "$QUEUE_ROOT/$p/"
  done
  [ -d "$QUEUE_ROOT/runs" ] && mv "$QUEUE_ROOT/runs" "$QUEUE_ROOT/$p/runs"
  echo "✅ 구 state → state/$p/ 이동 완료"
}

# 구 레이아웃 자동 이행 — run.sh 재시작 대비(중지→풀→재시작 시 진행 중이던 실행 보존).
# 프로젝트가 확정된 문맥에서만 호출할 것. rc: 0=이행했거나 불필요, 3=충돌(구·신 둘 다 존재).
queue_automigrate_for(){   # <프로젝트>
  local p="${1:?사용법: queue_automigrate_for <프로젝트>}"
  [ -f "$QUEUE_ROOT/handoff.json" ] || return 0
  if [ -f "$QUEUE_ROOT/$p/handoff.json" ]; then
    echo "❌ 구 state(state/handoff.json)와 신 state(state/$p/)가 둘 다 존재 — 자동 이행 불가." >&2
    echo "   진행 중이던 쪽을 남기고 다른 쪽을 백업/삭제하거나, 구 쪽이 다른 프로젝트면: bash queue.sh migrate <그 프로젝트명>" >&2
    return 3
  fi
  echo "♻️ 구 state 레이아웃 감지 → state/$p/ 로 자동 이행(진행 중이던 실행 보존, M0 재개 가드가 이어받음)"
  queue_migrate "$p"
}

queue_add(){   # <프로젝트> [mode]
  local p="${1:?프로젝트명 필요}" m="${2:-auto}"
  queue_guard_legacy || return 2
  case "$m" in auto|lite|full) ;; *) echo "❌ mode는 auto|lite|full" >&2; return 2 ;; esac
  [ -d "$PIPELINE_DIR/spec/$p" ] || { echo "❌ spec/$p/ 없음 — 기획서를 먼저 넣으세요" >&2; return 2; }
  local id="q-$(date +%Y%m%d-%H%M%S)-$RANDOM"
  queue_edit ".items += [{id:\"$id\",project:\"$p\",mode:\"$m\",mode_resolved:null,status:\"queued\",request:null,progress:null,enqueued_at:\"$(_q_now)\",started_at:null,finished_at:null,result:null,paused_reason:null}]" \
    && echo "➕ 큐 등록: $id ($p, mode=$m)"
}

queue_list(){
  queue_init
  echo "── 큐 (state/queue.json) ──"
  jq -r '.items[] | "\(.status)\t\(.project)\t\(.mode)\(if .mode_resolved then "→"+.mode_resolved else "" end)\t\(.progress // {} | if .total then "\(.done)/\(.total)" else "-" end)\t\(.result // "")\t\(.id)"' "$QUEUE_FILE" \
    | column -t -s $'\t' 2>/dev/null || jq . "$QUEUE_FILE"
}

queue_claim(){   # 첫 queued → running + worker 블록. stdout=id, 없으면 rc=1
  queue_lock || return 1
  queue_init
  local id; id="$(jq -r '[.items[]|select(.status=="queued")][0].id // empty' "$QUEUE_FILE")"
  [ -z "$id" ] && { queue_unlock; return 1; }
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" --arg ts "$(_q_now)" --argjson pid $$ \
     '(.items[]|select(.id==$id)) |= (.status="running"|.started_at=$ts)
      | .worker={pid:$pid,current_id:$id,heartbeat_at:$ts}' \
     "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
  queue_unlock
  echo "$id"
}

# 죽은 워커의 running 항목 회수 → paused(stale)
queue_recover_stale(){
  local wpid; wpid="$(queue_get '.worker.pid // empty')"
  [ -n "$wpid" ] || return 0
  kill -0 "$wpid" 2>/dev/null && return 0
  queue_edit '(.items[]|select(.status=="running")) |= (.status="paused"|.paused_reason="stale") | .worker=null'
  echo "♻️ 스테일 워커(pid=$wpid) 회수 — running 항목을 paused(stale)로"
}

# run.sh가 역할 턴 사이에 호출. UI request 존중: pause→exit 4, cancel→exit 5.
queue_checkpoint(){
  [ -n "${QUEUE_ITEM_ID:-}" ] || return 0
  queue_heartbeat
  local req; req="$(queue_item_get "$QUEUE_ITEM_ID" '.request // empty')"
  case "$req" in
    pause)
      queue_item_set "$QUEUE_ITEM_ID" '.status="paused"|.paused_reason="user"|.request=null'
      echo "⏸️ UI pause 요청 — 항목 중단(재개: status를 queued로)"; exit 4 ;;
    cancel)
      queue_item_set "$QUEUE_ITEM_ID" ".status=\"cancelled\"|.request=null|.finished_at=\"$(_q_now)\""
      echo "⏹️ UI cancel 요청 — 항목 취소"; exit 5 ;;
  esac
}

# run.sh 마일스톤 훅에서 진행도 미러 (큐 모드일 때만)
queue_progress(){   # <done> <total> <current_task>
  [ -n "${QUEUE_ITEM_ID:-}" ] || return 0
  local t; t="$(printf '%s' "$3" | head -c 120 | sed 's/"/\\"/g')"
  queue_item_set "$QUEUE_ITEM_ID" ".progress={done:${1:-0},total:${2:-0},current_task:\"$t\"}"
}
queue_mode_resolved(){   # <lite|full>
  [ -n "${QUEUE_ITEM_ID:-}" ] || return 0
  queue_item_set "$QUEUE_ITEM_ID" ".mode_resolved=\"$1\""
}

queue_finish_item(){   # <id> <rc> — run.sh 종료코드를 항목 상태로 매핑
  local id="$1" rc="$2" st
  st="$(queue_item_get "$id" '.status')"
  case "$st" in paused|cancelled) return 0 ;; esac   # 체크포인트가 이미 기록(rc 4/5 포함)
  local now; now="$(_q_now)"
  case "$rc" in
    0) queue_item_set "$id" ".status=\"done\"|.result=\"green\"|.finished_at=\"$now\"" ;;
    1) queue_item_set "$id" ".status=\"failed\"|.result=\"failed:verify\"|.finished_at=\"$now\"" ;;
    2) local q p; p="$(queue_item_get "$id" '.project')"
       q="$(grep -m1 -v -e '^[[:space:]]*$' -e '^#' -e '^<!--' "$QUEUE_ROOT/$p/questions.md" 2>/dev/null | head -c 80 || true)"
       q="$(printf '%s' "$q" | sed 's/"/\\"/g')"
       queue_item_set "$id" ".status=\"paused\"|.paused_reason=\"blocker\"|.result=\"blocked:${q:-질문 확인 필요}\"" ;;
    3) queue_item_set "$id" ".status=\"paused\"|.paused_reason=\"human\"" ;;
    *) queue_item_set "$id" ".status=\"failed\"|.result=\"failed:crash(rc=$rc)\"|.finished_at=\"$now\"" ;;
  esac
}

queue_work(){
  queue_guard_legacy || return 2
  # 로컬 세팅 마이그레이션 — 풀 받은 세팅 버전이 이 기기보다 앞서면 자동 적용. OLYMPUS_SETUP=0 으로 끔.
  [ "${OLYMPUS_SETUP:-1}" = "0" ] || { [ -f "$PIPELINE_DIR/setup.sh" ] && . "$PIPELINE_DIR/setup.sh" && setup_apply; } || true
  # 큐 웹 UI 자동 기동 — 큐가 비어 run.sh까지 못 가도 UI는 뜬다. OLYMPUS_UI=0 으로 끔.
  [ "${OLYMPUS_UI:-1}" = "0" ] || bash "$PIPELINE_DIR/ui.sh" autostart "${OLYMPUS_UI_PORT:-8765}" || true
  queue_recover_stale
  local id rc n=0
  while id="$(queue_claim)"; do
    local p m
    p="$(queue_item_get "$id" '.project')"; m="$(queue_item_get "$id" '.mode')"
    echo "▶▶ [$((n+1))] 큐 실행: $id — $p (mode=$m)"
    PROJECT="$p" QUEUE_ITEM_ID="$id" OLYMPUS_MODE="$m" bash "$PIPELINE_DIR/run.sh"
    rc=$?
    queue_finish_item "$id" "$rc"
    echo "◀◀ $p 종료(rc=$rc) → $(queue_item_get "$id" '.status') $(queue_item_get "$id" '.result // ""')"
    n=$((n+1))
  done
  queue_edit '.worker=null'
  if [ "$n" -gt 0 ]; then queue_drain_notify "$n"; else echo "ℹ️ 큐가 비어 있음"; fi
}

queue_watch(){   # 상시 대기 모드 — 큐를 폴링하다 등록되면 곧 집어간다(웹 UI가 제어면). 중지: Ctrl+C
  local interval="${1:-5}"
  queue_guard_legacy || return 2
  [ "${OLYMPUS_SETUP:-1}" = "0" ] || { [ -f "$PIPELINE_DIR/setup.sh" ] && . "$PIPELINE_DIR/setup.sh" && setup_apply; } || true
  [ "${OLYMPUS_UI:-1}" = "0" ] || bash "$PIPELINE_DIR/ui.sh" autostart "${OLYMPUS_UI_PORT:-8765}" || true
  queue_recover_stale
  echo "👀 큐 감시 시작(${interval}s 간격, 중지: Ctrl+C) — 등록: 웹 UI http://127.0.0.1:${OLYMPUS_UI_PORT:-8765} 또는 bash queue.sh add"
  while :; do
    if [ "$(queue_get '[.items[]|select(.status=="queued")]|length' 2>/dev/null || echo 0)" -gt 0 ]; then
      queue_work
    fi
    sleep "$interval"
  done
}

# 큐 드레인 종합 알림 (milestones.sh의 milestone_notify 재사용, best-effort)
queue_drain_notify(){
  command -v milestone_notify >/dev/null 2>&1 || { [ -f "$PIPELINE_DIR/milestones.sh" ] && . "$PIPELINE_DIR/milestones.sh"; }
  command -v milestone_notify >/dev/null 2>&1 || return 0
  local bf; bf="$(mktemp)"
  { echo "큐 소진 — 이번 세션 ${1}건 처리."; echo
    jq -r '.items[] | "\(.status)\t\(.project)\t\(.mode_resolved // .mode)\t\(.result // "-")"' "$QUEUE_FILE" \
      | column -t -s $'\t' 2>/dev/null
  } > "$bf"
  milestone_notify "[올림푸스] 큐 완료 — ${1}건 처리" "$bf"; rm -f "$bf"
  return 0
}

# ── CLI ──
if [ -z "${QUEUE_LIB:-}" ]; then
  set -uo pipefail
  cmd="${1:-list}"; shift || true
  case "$cmd" in
    add)    p="${1:?프로젝트명}"; m="auto"; [ "${2:-}" = "--mode" ] && m="${3:-auto}"; queue_add "$p" "$m" ;;
    list)   queue_list ;;
    work)   # config 로드(모델·알림 env) 후 루프. --watch [간격초]=상시 대기(등록되면 자동 실행)
            . "$PIPELINE_DIR/config.sh" 2>/dev/null || true
            if [ "${1:-}" = "--watch" ]; then queue_watch "${2:-5}"; else queue_work; fi ;;
    migrate) queue_migrate "${1:?프로젝트명}" ;;
    *) echo "사용: bash queue.sh add <프로젝트> [--mode lite|full] | list | work [--watch [간격초]] | migrate <프로젝트>"; exit 2 ;;
  esac
fi
