#!/usr/bin/env bash
# prompts.sh — 세션 프롬프트 조립 (참조 기반 최소 주입). run.sh에서 `. prompts.sh`로 소스.
# 필요 전역: PIPELINE_DIR, TARGET_REPO, SPEC_DIR(metis M0), MODE(선택). 순수 bash 3.2+.
#
# 원칙: 대형 문서(spec, requirements)는 인라인하지 않는다 — 경로를 주고 세션이
#       --add-dir 권한으로 직접 읽는다. 소형 핫 파일(질문 큐·피드백·진행 저널)만 인라인.
#       프롬프트가 참조 기반이면 토큰 대기(resilience.sh) 후 같은 프롬프트로
#       재시도해도 새 세션이 런타임에 최신 state를 읽어 남은 작업만 이어간다.

_inline_file() {  # <섹션 제목> <파일 경로>
  echo "## $1"
  if [ -s "$2" ]; then cat "$2"; else echo "(비어 있음)"; fi
  echo
}

paths_header () {
  cat <<EOF
## 경로 (절대경로 — 반드시 이걸 사용)
- 코드 작업 대상(현재 디렉토리): $TARGET_REPO
- 개발 모드: ${MODE:-미정}
- 파이프라인 상태 디렉토리: ${STATE_DIR:-$PIPELINE_DIR/state}
- 역할/스펙 디렉토리: $PIPELINE_DIR
- 원본 기획서(spec) 디렉토리: ${SPEC_DIR:-$PIPELINE_DIR/spec}
상태/스펙(spec/ 폴더, state/*.md, handoff.json)은 위 PIPELINE 경로 기준이고, 코드 변경은 TARGET_REPO에 한다.
개발 모드가 brownfield면 **기존 구조·규약을 따르고 최소 변경·동작 보존**, 기존 테스트를 깨지 않는다.
큰 문서(spec, requirements 등)는 이 프롬프트에 인라인되어 있지 않다 — 필요한 것만 위 경로에서 직접 읽어라.
EOF
}

metis_prompt () {  # <M0|M1|M2>
  local mode="$1"
  cat "$PIPELINE_DIR/roles/metis.md"; echo
  paths_header; echo
  echo "## 이번 호출 모드: $mode"
  case "$mode" in
    M0)
      # requirements.md가 이미 채워져 있으면 = 중단됐던 실행의 재시작. 재분석하면
      # 진행 중이던 backlog/task를 덮어쓸 수 있으므로 코드에서 결정적으로 분기한다.
      if [ -s "${STATE_DIR:-$PIPELINE_DIR/state}/requirements.md" ]; then
        echo "M0(재시작): state/requirements.md가 이미 채워져 있다 — 중단됐던 실행의 재개다."
        echo "전면 재분석·백로그 재분해를 하지 마라. 할 일만 한다:"
        echo "① state/human-answers.md에 새 답이 있으면 requirements.md/decisions.md에 반영,"
        echo "② requirements/backlog/task/handoff 간 정합성만 점검(모순이 있을 때만 최소 보정),"
        echo "③ 진행 중이던 task.md·progress.md를 보존하고 handoff.json의 기존 status/turn대로 루프를 재개시켜라."
      else
        echo "M0(요구사항 분석)을 수행하라. 원본 기획서는 ${SPEC_DIR:-$PIPELINE_DIR/spec} 안의 모든 .md 문서다 — 직접 읽어라."
        echo "state/human-answers.md에 사람 답이 있으면 최우선으로 반영하라."
        case "${OLYMPUS_MODE:-full}" in
          lite) echo "라이트 모드: 요구사항 분석은 핵심만 간결히, 백로그는 1~2개 작업으로만 분해하라(과분해 금지)." ;;
          auto) echo "분석을 마치면 규모를 스스로 판정해 handoff.json에 \"mode\" 필드를 추가하라 — 예상 작업 3개 이하·단일 모듈이면 \"lite\", 아니면 \"full\". lite로 판정했다면 백로그를 1~2개 작업으로만 분해하라." ;;
        esac
      fi
      ;;
    M1)
      echo "M1(질문 응답)을 수행하라. 네 기억은 state/requirements.md·decisions.md에 있다 — 직접 읽어라. 필요하면 원본 spec도 직접 읽어라."
      echo
      _inline_file "PENDING QUESTIONS (다른 세션 → 기획자, 의도)" "${STATE_DIR:-$PIPELINE_DIR/state}/ask-planner.md"
      ;;
    M2)
      echo "M2(결함 트리아지 + 다음 작업)를 수행하라. 판단 근거(state/requirements.md·decisions.md)는 직접 읽어라."
      echo "다음 작업을 task.md로 복사한 뒤 state/progress.md를 초기화하라(빈 파일로)."
      echo
      _inline_file "FINDINGS (Critic이 올린 범위 밖 결함 — 트리아지 대상)" "${STATE_DIR:-$PIPELINE_DIR/state}/findings.md"
      _inline_file "BACKLOG" "${STATE_DIR:-$PIPELINE_DIR/state}/backlog.md"
      ;;
  esac
}

worker_prompt () {  # <역할파일 경로>
  cat "$1"; echo
  paths_header; echo
  _inline_file "CURRENT TASK (현재 작업 + 수용 기준)" "${STATE_DIR:-$PIPELINE_DIR/state}/task.md"
  _inline_file "PROGRESS JOURNAL (이번 작업 진행 저널 — 완료된 것은 건너뛰고 남은 것부터 이어서)" "${STATE_DIR:-$PIPELINE_DIR/state}/progress.md"
  _inline_file "LATEST CRITIC FEEDBACK" "${STATE_DIR:-$PIPELINE_DIR/state}/critic-feedback.md"
  echo "기획자 의도가 필요하면 state/requirements.md를 직접 읽어라(이 프롬프트에 인라인되어 있지 않다)."
}
