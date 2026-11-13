#!/usr/bin/env bash
# Olympus 오케스트레이터 = "헤르메스 라우터"의 로컬판. (standalone: 대상 repo와 분리)
# 기획서(spec/ 폴더의 문서들)만 넣으면 → (필수)요구사항 분석 → 작업별 Builder↔Critic 루프(작업단위 승인 없음) → 전부 완료 후 1회 사람 승인.
# 모호함은 가정으로 진행 + open-questions에 누적(진짜 블로커만 도중 중단).
#
# 전제: Claude Code CLI(`claude`) 설치. 대상 repo와 검증 명령은 config.sh에서 지정.
# ⚠️ `claude` 플래그(--add-dir, --model, --permission-mode)는 네 버전에 맞게 조정.
#     처음엔 수동(README B)으로 한 바퀴 검증 후 자동화 권장.
#
# 사용: bash run.sh   (config.sh의 TARGET_REPO/VERIFY_CMD/모델/예산을 읽음)
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$PIPELINE_DIR"
# spec/<프로젝트>/run.env 우선순위 판정용 — 사용자가 "명시적으로" 넘긴 env를
# config.sh(기본값 주입) 로드 전에 스냅샷해 둔다. 계약: 명시적 env > run.env > config.sh 기본값.
_OLY_USER_VARS=""
for _v in TARGET_REPO GIT_BRANCH VERIFY_CMD AUTO_MERGE DEPLOY_ON_DONE ARCHIVE_ON_DONE REMOTE OLYMPUS_MODE MAX_ROUNDS AUTO_APPROVE; do
  if eval "[ -n \"\${${_v}+x}\" ]"; then
    _OLY_USER_VARS="$_OLY_USER_VARS $_v"
    eval "_OLY_USER_${_v}=\"\${${_v}}\""
  fi
done
# shellcheck source=/dev/null
source "$PIPELINE_DIR/config.sh"

# 원격 결정 브리지(있으면)
[ -f "$PIPELINE_DIR/remote.sh" ] && . "$PIPELINE_DIR/remote.sh"
[ -f "$PIPELINE_DIR/gitops.sh" ] && . "$PIPELINE_DIR/gitops.sh"
[ -f "$PIPELINE_DIR/finalize.sh" ] && . "$PIPELINE_DIR/finalize.sh"
[ -f "$PIPELINE_DIR/deploy.sh" ] && . "$PIPELINE_DIR/deploy.sh"
[ -f "$PIPELINE_DIR/resilience.sh" ] && . "$PIPELINE_DIR/resilience.sh"
[ -f "$PIPELINE_DIR/milestones.sh" ] && . "$PIPELINE_DIR/milestones.sh"
[ -f "$PIPELINE_DIR/queue.sh" ] && QUEUE_LIB=1 . "$PIPELINE_DIR/queue.sh"   # 큐 모드(QUEUE_ITEM_ID) 체크포인트/미러 — 없으면 전부 no-op
. "$PIPELINE_DIR/prompts.sh"   # 세션 프롬프트 조립(참조 기반 최소 주입)
# 로컬 세팅 마이그레이션 — 풀 받은 세팅 버전이 이 기기보다 앞서면 자동 적용. OLYMPUS_SETUP=0 으로 끔.
[ "${OLYMPUS_SETUP:-1}" = "0" ] || { [ -f "$PIPELINE_DIR/setup.sh" ] && . "$PIPELINE_DIR/setup.sh" && setup_apply; } || true
# 큐 웹 UI 자동 기동 — 멱등(이미 떠 있으면 no-op), 실패해도 실행에 무영향. OLYMPUS_UI=0 으로 끔.
[ "${OLYMPUS_UI:-1}" = "0" ] || bash "$PIPELINE_DIR/ui.sh" autostart "${OLYMPUS_UI_PORT:-8765}" || true
# 429/529(일시 용량)는 CLI 워치독에 위임; 사용량 한도만 resilience.sh가 대기 처리.
[ "${TOKEN_WAIT:-1}" = "1" ] && export CLAUDE_CODE_RETRY_WATCHDOG="${CLAUDE_CODE_RETRY_WATCHDOG:-1}"

# ── 대상 프로젝트 결정 (우선순위: PROJECT env → TARGET_REPO → spec 첫 폴더) ──
#    상태(state/<프로젝트>/)와 로그가 프로젝트별로 격리되므로 가장 먼저 결정한다.
PROJECT_EXPLICIT=0   # 1=사용자가 지정했거나 후보가 하나뿐(구 state 자동 이행을 믿어도 되는 경우)
if [ -n "${PROJECT:-}" ]; then
  SPEC_DIR="$PIPELINE_DIR/spec/$PROJECT"
  [ -d "$SPEC_DIR" ] || { echo "❌ spec/$PROJECT/ 없음 — 기획서를 먼저 넣으세요."; exit 2; }
  PROJECT_EXPLICIT=1
elif [ -n "${TARGET_REPO:-}" ]; then
  PROJECT="$(basename "$TARGET_REPO")"
  if [ -d "$PIPELINE_DIR/spec/$PROJECT" ]; then SPEC_DIR="$PIPELINE_DIR/spec/$PROJECT"; else SPEC_DIR="$PIPELINE_DIR/spec"; fi
  PROJECT_EXPLICIT=1
else
  _CANDS="$(find "$PIPELINE_DIR/spec" -mindepth 1 -maxdepth 1 -type d ! -name '_*' -exec basename {} \; 2>/dev/null | sort)"
  PROJECT="$(printf '%s\n' "$_CANDS" | head -1)"
  [ -n "$PROJECT" ] || { echo "❌ spec/<프로젝트폴더>/ 가 없습니다. 기획서를 spec/<이름>/*.md 로 넣으세요."; exit 2; }
  [ "$(printf '%s\n' "$_CANDS" | grep -c .)" = "1" ] && PROJECT_EXPLICIT=1
  SPEC_DIR="$PIPELINE_DIR/spec/$PROJECT"
fi

# ── spec별 실행 설정: spec/<프로젝트>/run.env (2026-07-09) ──
# UI/큐 실행은 PROJECT만 전달되므로, 대상 repo·브랜치·게이트를 spec 폴더가 스스로 선언한다.
# (버전 폴더 규약 spec/<repo>-vX.Y.Z/처럼 폴더명 ≠ repo명이어도 재기동·수동 env 없이 자동으로 맞음.)
# 우선순위: 명시적 env(스냅샷) > run.env > config.sh 기본값/폴더명 추측.
if [ -f "$SPEC_DIR/run.env" ]; then
  echo "🧾 spec 실행 설정 로드: $(basename "$SPEC_DIR")/run.env"
  # shellcheck source=/dev/null
  . "$SPEC_DIR/run.env"
  for _v in $_OLY_USER_VARS; do eval "${_v}=\"\${_OLY_USER_${_v}}\""; done
fi
TARGET_REPO="${TARGET_REPO:-$PROJECTS_DIR/$PROJECT}"
# verify.sh는 `bash verify.sh` 자식으로 실행되므로 게이트 값들을 반드시 export 한다.
# (export 누락 시 verify.sh가 config 기본값 VERIFY_CMD="bash verify.sh"로 떨어져 자기 자신을 재귀 실행 → fork 폭탄)
export TARGET_REPO VERIFY_CMD
export STATE_DIR="$PIPELINE_DIR/state/$PROJECT"
mkdir -p "$STATE_DIR"

# ── 구(단일 state) 레이아웃 재시작 대비 ──
#    구버전으로 진행 중이던 실행을 중지 → 풀 → 재시작하면 상태가 state/ 루트에 남아 있다.
#    그대로 두면 새 경로(state/<프로젝트>/)가 비어 있어 처음부터 재분석해버리므로 자동 이행한다.
if [ -f "$PIPELINE_DIR/state/handoff.json" ]; then
  if [ "$PROJECT_EXPLICIT" = "1" ] && command -v queue_automigrate_for >/dev/null 2>&1; then
    queue_automigrate_for "$PROJECT" || exit 2
  else
    echo "❌ 구 state(state/handoff.json)가 남아 있는데 spec 후보가 여러 개라 프로젝트를 추정할 수 없음 — 진행 중이던 실행 보호를 위해 중단."
    echo "   진행 중이던 프로젝트를 지정해 다시 실행: PROJECT=<이름> bash run.sh   (또는 bash queue.sh migrate <이름> 후 재실행)"
    exit 2
  fi
fi

# 배포 단계: 규약(DEPLOY_CMD/state/deploy.md)이 있으면 따르고, 없으면 사용자에게 묻는다.
run_deploy_phase () {
  [ "${DEPLOY_ON_DONE:-1}" = "1" ] || return 0
  command -v deploy_project >/dev/null 2>&1 || return 0
  deploy_project; local drc=$?
  [ "$drc" -ne 10 ] && return 0   # 규약대로 배포 수행함(성공/실패는 deploy_project가 로깅)
  # 규약 전무 → 마지막에 사람에게 반드시 질문
  local dcmd rc
  if remote_enabled 2>/dev/null; then
    local DQ; DQ="$(mktemp)"
    { echo "배포 규약이 기획서/설정에 없습니다.";
      echo; echo "배포하려면 답변에 **배포 명령**을 적어주세요 (예: git push origin main).";
      echo "배포하지 않으려면 skip 이라고 적어주세요."; } > "$DQ"
    dcmd="$(remote_ask "$(date +%Y%m%d-%H%M%S)" "deploy" "배포 방법 확인(규약 없음)" "$DQ")"; rc=$?
    rm -f "$DQ"
    [ "$rc" -ne 0 ] && { echo "⏱️ 배포 응답 타임아웃 — 배포 스킵."; return 0; }
  else
    read -r -p "배포 규약 없음. 배포 명령 입력(없으면 skip): " dcmd
  fi
  case "${dcmd:-skip}" in
    skip|SKIP|Skip|"") echo "⏭️ 배포 스킵(규약 없음)." ;;
    *) echo "🚀 사용자 지정 배포: $dcmd"; ( cd "$TARGET_REPO" && eval "$dcmd" ) \
         && echo "✅ 배포 완료" || echo "⚠️ 배포 실패" ;;
  esac
}

# 원격이면 질문 파일을 push·폴링, 답을 human-answers.md에 append하고 0 반환.
# 원격 아님/타임아웃이면 1 반환(호출부가 기존 exit 2 수행).
ask_human_or_stop(){   # <type> <title> <questionfile>
  local type="$1" title="$2" qf="$3"
  # 큐 모드: 원격 폴링으로 큐를 정체시키지 않는다 — 즉시 1 반환(호출부가 exit,
  # queue.sh가 항목만 paused(blocker)로 눕히고 다음 항목 진행).
  [ -n "${QUEUE_ITEM_ID:-}" ] && return 1
  remote_enabled || return 1
  local id; id="$(date +%Y%m%d-%H%M%S)"
  local ans; ans="$(remote_ask "$id" "$type" "$title" "$qf")"; local rc=$?
  [ "$rc" -ne 0 ] && { echo "⏱️ 원격 응답 타임아웃 → 로컬 중단 폴백"; return 1; }
  {
    printf '\n## [%s] %s (id=%s)\n' "$type" "$title" "$id"
    printf '**질문:**\n'; cat "$qf"
    printf '\n**사람 답:**\n%s\n' "$ans"
  } >> "$STATE_DIR/human-answers.md"
  echo "✅ 원격 답 수신(id=$id) → human-answers.md 반영, 계속"
  return 0
}

# ── 무인 실행 로그 (state/runs/ 에 타임스탬프별로 남김) ──
mkdir -p "$STATE_DIR/runs"
LOG="$STATE_DIR/runs/run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
RUN_ID="$(basename "$LOG" .log)"

# ── 토큰 사용량 기록 (최적화 검토용 · 가산형 · 비침습) ──
#   각 역할의 claude 호출 뒤, 그 세션 기록(~/.claude/projects/<repo>/*.jsonl)을 읽어
#   run/round/role/model별 토큰을 state/usage.tsv 에 append 한다.
#   claude 호출/출력은 전혀 건드리지 않음(read-only). USAGE_TRACK=0 이면 끔.
USAGE_TRACK="${USAGE_TRACK:-1}"
USAGE_LOG="$STATE_DIR/usage.tsv"
_cc_proj_dir() { printf '%s/.claude/projects/%s' "$HOME" "$(printf '%s' "$TARGET_REPO" | sed 's|[/.]|-|g')"; }
log_usage() {   # $1=role $2=model $3=marker파일(호출 직전 생성됨)
  if [ "$USAGE_TRACK" != "1" ]; then rm -f "$3" 2>/dev/null; return 0; fi
  local dir sums; dir="$(_cc_proj_dir)"
  if [ -d "$dir" ]; then
    sums="$(find "$dir" -name '*.jsonl' -newer "$3" 2>/dev/null | while IFS= read -r f; do cat "$f"; done \
      | jq -s -r '[.[]|select(.type=="assistant" and .message.usage)|.message.usage]
          | "\(((map(.input_tokens//0)|add)//0))\t\(((map(.output_tokens//0)|add)//0))\t\(((map(.cache_read_input_tokens//0)|add)//0))\t\(((map(.cache_creation_input_tokens//0)|add)//0))"' 2>/dev/null)"
    if [ -n "$sums" ] && [ "$sums" != "$(printf '0\t0\t0\t0')" ]; then
      [ -f "$USAGE_LOG" ] || printf 'ts\trun\tround\trole\tmodel\tinput\toutput\tcache_read\tcache_create\n' > "$USAGE_LOG"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$RUN_ID" "${r:-plan}" "$1" "$2" "$sums" >> "$USAGE_LOG"
    fi
  fi
  rm -f "$3" 2>/dev/null
}

# 이번 실행(run)의 토큰 사용량 요약을 stdout으로. (완료 로그·완료메일에 사용)
usage_summary() {
  [ -f "$USAGE_LOG" ] || { echo "  (토큰 기록 없음)"; return 0; }
  awk -F'\t' -v run="$RUN_ID" '
    function price(m){ if(m~/opus/)return "5 25"; else if(m~/haiku/)return "1 5"; else if(m~/sonnet/)return "3 15"; else if(m~/glm/)return "0.6 2.2"; else return "3 15" }
    NR>1 && $2==run {
      role=$4;model=$5;i=$6;o=$7;cr=$8;cc=$9;
      split(price(model),p," "); cost=(i*p[1]+cr*p[1]*0.1+cc*p[1]*1.25+o*p[2])/1e6;
      Rn[role]++;Ri[role]+=i;Ro[role]+=o;Rc[role]+=cr;Rcost[role]+=cost;
      Ti+=i;To+=o;Tcr+=cr;Tcc+=cc;Tcost+=cost;n++;
    }
    END{
      if(n==0){print "  (이번 실행 토큰 기록 없음)";exit}
      printf "%-9s %5s %10s %10s %10s %8s\n","역할","호출","입력","출력","캐시읽기","환산$";
      for(r in Ri) printf "%-9s %5d %10d %10d %10d %8.2f\n",r,Rn[r],Ri[r],Ro[r],Rc[r],Rcost[r];
      printf "합계  입력 %d · 출력 %d · 캐시읽기 %d · 캐시쓰기 %d\n",Ti,To,Tcr,Tcc;
      printf "API 환산가치 ≈ $%.2f (실제 Pro/Max 청구 아님 · 최적화 참고용)\n",Tcost;
    }' "$USAGE_LOG"
}
echo "▶ run 시작 $(date '+%F %T') — target=$TARGET_REPO — 로그: $LOG"

# state는 런타임(git 미추적). 없으면 자동 초기화 → 새 클론/새 작업에서도 바로 동작.
if [ ! -f "$STATE_DIR/handoff.json" ]; then
  echo "ℹ️ state 미존재 → 자동 초기화(reset.sh)"
  bash "$PIPELINE_DIR/reset.sh" "$PROJECT" >/dev/null
fi

read_status () {
  grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_DIR/handoff.json" \
    | sed 's/.*"\([^"]*\)"$/\1/' | head -1
}

read_turn () {
  grep -o '"turn"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_DIR/handoff.json" \
    | sed 's/.*"\([^"]*\)"$/\1/' | head -1
}

# Critic이 사람 에스컬레이션(turn=human)을 걸면 무인 진행을 멈춘다(심판변경/보안·스펙 중대위반).
pause_if_human () {
  if [ "$(read_turn)" = "human" ]; then
    echo "🟠 사람 에스컬레이션(turn=human) — 자동 진행 중단. 사유는 critic-feedback.md 참고:"
    echo "------------------------------------------------------------"
    sed -n '1,50p' "$STATE_DIR/critic-feedback.md" 2>/dev/null
    echo "------------------------------------------------------------"
    echo "처리 후 다시 'bash run.sh'로 재개(맥락은 state/ durable 파일로 유지)."
    exit 3
  fi
}

# 기획자(메티스): 매 호출 새 세션(무상태). 기억은 state 파일(requirements/decisions/backlog).
# 프롬프트는 prompts.sh가 모드별 최소 주입으로 조립한다.
metis () {   # <M0|M1|M2>
  local _m; _m="$(mktemp)"
  ( cd "$TARGET_REPO" && claude_guarded -p "$(metis_prompt "$1")" \
      --add-dir "$PIPELINE_DIR" --model "$PLANNER_MODEL" $PERMISSION_FLAG )
  local _rc=$?
  log_usage "metis" "$PLANNER_MODEL" "$_m"
  return $_rc
}

# Builder/Critic 호출. ($1=역할파일 $2=모델)
worker () {
  local _m _role; _m="$(mktemp)"; _role="$(basename "$1" .md)"
  ( cd "$TARGET_REPO" && claude_guarded -p "$(worker_prompt "$1")" \
      --add-dir "$PIPELINE_DIR" --model "$2" $PERMISSION_FLAG )
  local _rc=$?
  log_usage "$_role" "$2" "$_m"
  return $_rc
}

# 세션이 의도 질문(needs_intent)을 남겼으면 기획자에게 라우팅해 해소.
resolve_intent () {
  while [ "$(read_status)" = "needs_intent" ]; do
    echo "  ↳ needs_intent → 기획자(메티스)에게 질문 라우팅"
    metis M1
    [ "$(read_status)" = "needs_clarification" ] && return 1
  done
  return 0
}

echo "📁 프로젝트: $PROJECT → 대상: $TARGET_REPO (spec: $SPEC_DIR)"

# ── 존재 여부로 신규/수정 자동 판단 ──
if [ ! -d "$TARGET_REPO" ]; then
  # 없으면 → greenfield: 새로 생성 + git init + 범용 게이트 설치
  MODE="greenfield (새 프로젝트를 새로 만든다)"
  echo "🆕 $MODE — 생성: $TARGET_REPO"
  mkdir -p "$TARGET_REPO" && ( cd "$TARGET_REPO" && git init -q )
  if [ ! -f "$TARGET_REPO/verify.sh" ] && [ "$VERIFY_CMD" = "bash verify.sh" ]; then
    cp "$PIPELINE_DIR/templates/verify.sh" "$TARGET_REPO/verify.sh" && chmod +x "$TARGET_REPO/verify.sh"
    echo "🔧 게이트 설치: $TARGET_REPO/verify.sh"
  fi
else
  # 있으면 → brownfield: 기존 코드 수정. 안전하게 작업 브랜치 생성.
  MODE="brownfield (기존 코드를 수정/확장한다 — 동작 보존)"
  echo "🔁 $MODE — 기존 repo: $TARGET_REPO"
  if [ "${GIT_BRANCH:-auto}" != "none" ] && ( cd "$TARGET_REPO" && git rev-parse --git-dir >/dev/null 2>&1 ); then
    BASE_BRANCH="$( cd "$TARGET_REPO" && git rev-parse --abbrev-ref HEAD 2>/dev/null )"   # 승인 후 머지 대상
    B="${GIT_BRANCH:-auto}"; [ "$B" = "auto" ] && B="olympus/${PROJECT}-$(date +%Y%m%d-%H%M%S)"
    # 재개(중단 후 재실행)면 첫 실행의 기준·작업 브랜치를 이어받는다. 안 그러면 현재 브랜치(=이전 작업 브랜치)가
    # 기준으로 잡혀 최종 머지가 원래 기준 브랜치(main 등)에 닿지 못한다. 머지 성공 시 gitops.sh가 기록을 지운다.
    if [ -s "$STATE_DIR/base_branch" ] && [ -s "$STATE_DIR/work_branch" ] \
       && ( cd "$TARGET_REPO" && git rev-parse --verify -q "$(cat "$STATE_DIR/work_branch")" >/dev/null ); then
      BASE_BRANCH="$(cat "$STATE_DIR/base_branch")"; B="$(cat "$STATE_DIR/work_branch")"
      echo "↩️ 재개 — 기존 작업 브랜치 $B 이어받음"
    else
      printf '%s\n' "$BASE_BRANCH" > "$STATE_DIR/base_branch"; printf '%s\n' "$B" > "$STATE_DIR/work_branch"
    fi
    ( cd "$TARGET_REPO" && { git switch -c "$B" 2>/dev/null || git checkout -b "$B" 2>/dev/null || git switch "$B" 2>/dev/null || git checkout "$B" 2>/dev/null || true; } )
    echo "🌿 작업 브랜치: $B  (기준: ${BASE_BRANCH:-?} — 승인 시 여기로 머지)"
  fi
fi

# ── Phase 0: 요구사항 분석 (필수, 항상) ──
command -v queue_checkpoint >/dev/null 2>&1 && queue_checkpoint
echo "===== PHASE 0: 기획자 요구사항 분석 ($PLANNER_MODEL) ====="
metis M0
if [ "$(read_status)" = "needs_clarification" ]; then
  if ask_human_or_stop "blocker" "Phase0 블로커" "$STATE_DIR/questions.md"; then
    metis M0   # 답 반영해 재분석
  else
    echo "❓ 진짜 블로커 — 질문에 답해 spec/ 문서 보강 후 다시 실행:"
    echo "------------------------------------------------------------"
    cat "$STATE_DIR/questions.md"
    exit 2
  fi
fi

# 라이트 모드 해석: 강제(lite/full) 또는 auto면 메티스가 handoff.json에 기록한 판정
RESOLVED_MODE="${OLYMPUS_MODE:-full}"
if [ "$RESOLVED_MODE" = "auto" ]; then
  RESOLVED_MODE="$(jq -r '.mode // "full"' "$STATE_DIR/handoff.json" 2>/dev/null || echo full)"
fi
if [ "$RESOLVED_MODE" = "lite" ]; then
  MAX_ROUNDS=3
  echo "🪶 라이트 모드 — MAX_ROUNDS=3"
fi
command -v queue_mode_resolved >/dev/null 2>&1 && queue_mode_resolved "$RESOLVED_MODE"

# 🔔 마일스톤 1: Phase 0 완료(요구사항 분석·백로그 분해)
if command -v milestone_notify >/dev/null 2>&1; then
  read -r _md _mt < <(backlog_progress)
  _mbf="$(mktemp)"
  { echo "요구사항 분석 완료 — 작업 ${_mt}개로 분해."; echo; echo "── todo ──"
    if backlog_titles todo | grep -q .; then backlog_titles todo; else echo "(없음)"; fi; } > "$_mbf"
  milestone_notify "[올림푸스] 분석 완료 — 작업 ${_mt}개 ($PROJECT)" "$_mbf"; rm -f "$_mbf"
  command -v queue_progress >/dev/null 2>&1 && queue_progress "${_md:-0}" "${_mt:-0}" "분석 완료"
fi

# ── Phase 1: 작업별 Builder ↔ Critic 루프 (작업단위 승인 없음) ──
while true; do
  [ "$(read_status)" = "all_done" ] && { echo "✅ 백로그 전부 완료."; break; }

  echo "===== TASK: $(grep -m1 '##' "$STATE_DIR/task.md" || echo '(task)') ====="
  GREEN=0
  for ((r=1; r<=MAX_ROUNDS; r++)); do
    command -v queue_checkpoint >/dev/null 2>&1 && queue_checkpoint
    echo "--- round $r/$MAX_ROUNDS : BUILDER ($BUILDER_MODEL) ---"
    worker "$PIPELINE_DIR/roles/builder.md" "$BUILDER_MODEL"
    resolve_intent || ask_human_or_stop "intent" "의도 질문" "$STATE_DIR/ask-planner.md" \
      || { echo "❓ 사람 확인 필요(questions.md)"; exit 2; }

    bash "$PIPELINE_DIR/verify.sh"; V=$?

    command -v queue_checkpoint >/dev/null 2>&1 && queue_checkpoint
    echo "--- round $r/$MAX_ROUNDS : CRITIC ($CRITIC_MODEL) ---"
    worker "$PIPELINE_DIR/roles/critic.md" "$CRITIC_MODEL"
    resolve_intent || ask_human_or_stop "intent" "의도 질문" "$STATE_DIR/ask-planner.md" \
      || { echo "❓ 사람 확인 필요(questions.md)"; exit 2; }
    pause_if_human

    if [ "$(read_status)" = "green" ] && [ "$V" -eq 0 ]; then GREEN=1; break; fi
  done
  [ "$GREEN" -ne 1 ] && { echo "⛔ 예산($MAX_ROUNDS) 소진 — 사람 개입 필요."; exit 1; }

  echo "  작업 green ✅ → 다음 작업으로 (작업 단위 승인 없음)"
  commit_task "$(grep -m1 '##' "$STATE_DIR/task.md" | sed 's/^#* *//' || echo '작업')"   # 작업 브랜치에 커밋

  # 🔔 마일스톤 2: 작업 green+커밋 직후 (진행도 = done + doing, metis M2 이동 전이므로)
  if command -v milestone_notify >/dev/null 2>&1; then
    read -r _md _mt < <(backlog_progress)
    _mdoing="$(backlog_titles doing | grep -c . || echo 0)"; _mn=$(( _md + _mdoing ))
    _mtask="$(grep -m1 '##' "$STATE_DIR/task.md" | sed 's/^#* *//' || echo '작업')"
    _mbf="$(mktemp)"
    { echo "진행 ${_mn}/${_mt} — [${_mtask}] 완료"; echo; echo "── 남은 작업(todo) ──"
      if backlog_titles todo | grep -q .; then backlog_titles todo; else echo "남은 작업 없음"; fi; } > "$_mbf"
    milestone_notify "[올림푸스] 진행 ${_mn}/${_mt} — ${_mtask} 완료 ($PROJECT)" "$_mbf"; rm -f "$_mbf"
    command -v queue_progress >/dev/null 2>&1 && queue_progress "${_mn:-0}" "${_mt:-0}" "$_mtask"
  fi

  echo "===== 기획자: 다음 작업 선택 ====="
  metis M2
done

# ── 전체 완료: 최종 사람 승인 게이트 (기획서 전체에 대해 1회) ──
echo "===== 전체 백로그 완료 — 최종 검증 ====="
bash "$PIPELINE_DIR/verify.sh"; FV=$?

# 🔔 마일스톤 3: 전체 백로그 완료 — 최종 verify 직후 (머지 승인 요청은 기존 경로가 커버)
if command -v milestone_notify >/dev/null 2>&1; then
  read -r _md _mt < <(backlog_progress)
  _mst="$([ "$FV" -eq 0 ] && echo green || echo 실패)"
  _mbf="$(mktemp)"
  { [ "$FV" -eq 0 ] && echo "전체 완료 — verify green." || echo "전체 완료 — verify 실패(exit $FV).";
    echo; echo "완료 작업 ${_md}/${_mt}"; echo; echo "── 변경 요약 ──"
    ( cd "$TARGET_REPO" && git --no-pager diff --stat 2>/dev/null ); } > "$_mbf"
  milestone_notify "[올림푸스] 전체 완료 — verify ${_mst} ($PROJECT)" "$_mbf"; rm -f "$_mbf"
fi

echo; echo "── 누적 변경 요약 (target) ──"; ( cd "$TARGET_REPO" && git --no-pager diff --stat 2>/dev/null )
echo; echo "── 완료 작업 ──"; grep -E '^## \[done\]' "$STATE_DIR/backlog.md" 2>/dev/null
echo; echo "── 기획자 결정/변경 로그 ──"; sed -n '1,60p' "$STATE_DIR/decisions.md" 2>/dev/null
echo; echo "── 열린 질문(가정으로 진행함, 사람 확인 요망) ──"; sed -n '1,80p' "$STATE_DIR/open-questions.md" 2>/dev/null
echo; echo "── 이번 실행 토큰 사용량 (최적화 참고) ──"; usage_summary
echo
if [ "$FV" -ne 0 ]; then echo "⛔ 최종 verify 실패 — 머지 보류."; exit 1; fi
if [ "$AUTO_APPROVE" = "1" ]; then
  echo "✅ AUTO_APPROVE — 자동 승인."
  if [ "${AUTO_MERGE:-1}" = "1" ]; then
    if merge_work_branch; then
      run_deploy_phase
      [ "${ARCHIVE_ON_DONE:-1}" = "1" ] && finalize_project
    fi
  fi
  exit 0
fi
if remote_enabled; then
  APPROVE_Q="$(mktemp)"
  { echo "전체 개발 완료 + verify green. 아래 확인하고 머지 승인?"; echo;
    echo "── 변경 요약 ──"; ( cd "$TARGET_REPO" && git --no-pager diff --stat 2>/dev/null );
    echo; echo "── 열린 질문 ──"; sed -n '1,40p' "$STATE_DIR/open-questions.md" 2>/dev/null;
    echo; echo "── 이번 실행 토큰 사용량 (최적화 참고) ──"; usage_summary;
    echo; echo "승인하려면 답변에 y, 보류는 n."; } > "$APPROVE_Q"
  aid="$(date +%Y%m%d-%H%M%S)"
  if [ "${APPROVE_VIA_EMAIL:-1}" = "1" ]; then
    # 잦은 최종 승인은 Gmail 답장(첫 줄 y/n)으로 경량 처리
    a="$(remote_approve_email "$aid" "$APPROVE_Q")"; rc=$?
    if [ "$rc" -eq 4 ] || [ "$rc" -eq 5 ]; then
      echo "⚠️ IMAP 사용 불가(rc=$rc) — GitHub 승인 경로로 폴백." >&2
      a="$(remote_ask "$aid" "approval" "최종 머지 승인" "$APPROVE_Q")"; rc=$?
    fi
  else
    a="$(remote_ask "$aid" "approval" "최종 머지 승인" "$APPROVE_Q")"; rc=$?
  fi
  rm -f "$APPROVE_Q"
  [ "$rc" -ne 0 ] && { echo "⏱️ 승인 응답 타임아웃/불가 — 보류(수동 머지)."; exit 0; }
else
  read -r -p "전체 개발 완료 + verify green. 위 열린 질문 확인하고 머지 승인? [y/N] " a
fi
if [ "$a" = "y" ]; then
  echo "🎉 승인 완료."
  if [ "${AUTO_MERGE:-1}" = "1" ]; then
    if merge_work_branch; then
      bash "$PIPELINE_DIR/verify.sh" >/dev/null 2>&1 \
        && echo "✅ 머지 후 verify green" || echo "⚠️ 머지 후 verify 실패 — 확인 필요"
      run_deploy_phase                                        # 배포 규약 따르거나 사용자에게 질문
      [ "${ARCHIVE_ON_DONE:-1}" = "1" ] && finalize_project   # 기획 아카이브 + state 초기화
    fi
  else
    echo "(AUTO_MERGE=0 — 수동 머지: cd $TARGET_REPO && git merge ${B:-작업브랜치}; 이후 bash reset.sh로 정리)"
  fi
else
  echo "보류 — 직접 검토 후 수동 머지(작업 브랜치 ${B:-?})."
fi
