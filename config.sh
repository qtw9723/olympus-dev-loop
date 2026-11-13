#!/usr/bin/env bash
# Olympus 설정 — 대상 프로젝트와 검증 명령을 여기서 지정한다.
# 다른 프로젝트/언어로 바꾸려면 아래 TARGET_REPO / VERIFY_CMD 두 줄만 수정하면 된다.

# 새 프로젝트가 생성될 상위 디렉토리. spec/<이름>/ 의 <이름>으로 여기에 폴더가 자동 생성된다.
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"

# 개발 대상 repo (절대경로).
#   비워두면(기본) spec/<프로젝트>/ 폴더명으로 $PROJECTS_DIR 아래에 자동 결정·생성한다.
#   기존 repo를 직접 지정하고 싶을 때만 채운다.
TARGET_REPO="${TARGET_REPO:-}"

# 그라운드 트루스(심판) 명령 — TARGET_REPO에서 실행된다.
#   기본 bash verify.sh: 새 프로젝트엔 templates/verify.sh(범용 게이트)가 자동 설치된다.
#   기존 repo면 그 repo의 명령으로: "npm run verify" / "pytest -q" 등.
VERIFY_CMD="${VERIFY_CMD:-bash verify.sh}"

# 모델 (비평가는 생성자와 다른 모델 권장)
PLANNER_MODEL="${PLANNER_MODEL:-claude-opus-4-8}"
BUILDER_MODEL="${BUILDER_MODEL:-claude-sonnet-4-6}"
CRITIC_MODEL="${CRITIC_MODEL:-claude-opus-4-8}"

# 브라운필드(기존 repo 수정) 작업 브랜치.
#   auto = 자동 생성(olympus/<프로젝트>-<타임스탬프>) → 변경을 격리, 검토 후 머지
#   none = 현재 브랜치 그대로 / 또는 원하는 브랜치명 직접 지정
GIT_BRANCH="${GIT_BRANCH:-auto}"

# 루프 예산 / 승인
MAX_ROUNDS="${MAX_ROUNDS:-6}"
AUTO_APPROVE="${AUTO_APPROVE:-0}"   # 1이면 최종 머지 승인 프롬프트도 생략(완전 무인)
AUTO_MERGE="${AUTO_MERGE:-1}"       # 1이면 승인 시 작업 브랜치를 기준 브랜치로 자동 머지(0=수동)
ARCHIVE_ON_DONE="${ARCHIVE_ON_DONE:-1}"  # 1이면 머지 완료 후 기획서를 spec/_done/로 아카이브 + state 초기화
DEPLOY_ON_DONE="${DEPLOY_ON_DONE:-1}"    # 1이면 머지 후 배포 단계 수행(규약 있으면 실행, 없으면 사용자에게 질문)
DEPLOY_CMD="${DEPLOY_CMD:-}"             # 배포 명령(예: "git push origin main"). 비면 state/deploy.md(spec 유래) 사용

# ── 토큰 소진 자동 대기·재개 (resilience.sh) ──
TOKEN_WAIT="${TOKEN_WAIT:-1}"                       # 1=사용량 한도 시 대기 후 자동 재개, 0=끄기(기존 동작)
TOKEN_RETRY_SEC="${TOKEN_RETRY_SEC:-1200}"          # 리셋시각 파싱 불가 시 재시도 간격(초, 기본 20분)
TOKEN_RESET_BUFFER_SEC="${TOKEN_RESET_BUFFER_SEC:-60}"  # 파싱된 리셋시각에 더할 여유(초)
TOKEN_WAIT_CHUNK_SEC="${TOKEN_WAIT_CHUNK_SEC:-1800}"    # 한 번 sleep 최대 길이(초). 길면 나눠 자며 재확인
TOKEN_MAX_WAIT_SEC="${TOKEN_MAX_WAIT_SEC:-0}"       # 총 누적 대기 상한(초, 0=무제한)

# 권한 모드 — 헤드리스에서 세션이 파일쓰기/명령실행에 막히지 않게.
#   기본은 파일편집 자동승인. 단 스캐폴딩은 npm/pip 등 "명령 실행"이 많아 프롬프트로 멈출 수 있다.
#   완전 무인으로 돌리려면(특히 첫 스캐폴딩 포함) 아래로 바꾼다:
#     PERMISSION_FLAG="--dangerously-skip-permissions"
PERMISSION_FLAG="${PERMISSION_FLAG:---permission-mode acceptEdits}"

# ── 원격 결정 브리지 (Phase 1: Git) ──
REMOTE="${REMOTE:-0}"                                   # 1이면 사람 개입을 olympus-inbox 폴링으로 원격화
INBOX_DIR="${INBOX_DIR:-$HOME/projects/olympus-inbox}"  # olympus-inbox 로컬 클론 경로
INBOX_REMOTE="${INBOX_REMOTE:-}"                        # 예: git@github.com:<owner>/olympus-inbox.git (클론 자동생성용)
POLL_SEC="${POLL_SEC:-30}"                              # 폴링 간격(초)
POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-21600}"           # 답 대기 상한(초, 기본 6h) → 초과 시 안전 폴백
NOTIFY_EMAIL="${NOTIFY_EMAIL:-you@example.com}"       # 알림 수신 주소
NOTIFY_MILESTONES="${NOTIFY_MILESTONES:-1}"            # 1=진행도 마일스톤 메일 발송(기본), 0=로그 1줄만

# ── 최종 승인 경량화: Gmail 답장(IMAP) ──
#   블로커/의도질문은 GitHub(remote_ask) 그대로. 잦은 최종 승인만 답장으로 처리.
#   답장 첫 줄에 y(보류 n) → run.sh가 SMTP와 같은 Gmail 계정 IMAP을 폴링해 감지.
#   IMAP 비밀 없음/접속실패면 자동으로 GitHub 경로로 폴백(무손상).
APPROVE_VIA_EMAIL="${APPROVE_VIA_EMAIL:-1}"             # 1=최종 승인 Gmail 답장 / 0=기존 GitHub 경로
APPROVE_FROM="${APPROVE_FROM:-${SMTP_SENDER:-}}"        # 답장 허용 발신자(위조 차단). 기본 = 발송 계정

# 비밀은 .env.local(gitignore)에서만 로드 — 없으면 알림만 스킵
if [ -f "$(dirname "${BASH_SOURCE[0]}")/.env.local" ]; then
  set -a; . "$(dirname "${BASH_SOURCE[0]}")/.env.local"; set +a
fi
