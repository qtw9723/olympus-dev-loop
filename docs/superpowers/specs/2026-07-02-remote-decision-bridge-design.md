# 올림푸스 원격 결정 브리지 — 설계 (Phase 1: Git 브리지)

- 작성일: 2026-07-02
- 브랜치: `feat/remote-decision-bridge`
- 목적: 무인 실행 중 사람이 개입해야 하는 지점에서, **로컬 터미널 없이 폰(GitHub 앱)으로 결정을 내리고 전달**할 수 있게 한다.

## 배경 — 현재 "사람 결정" 지점 (원격 불가 원인)

`run.sh`에서 사람이 반드시 키보드 앞에 있어야 하는 지점은 3곳이다. 모두 **멈추고 사람을 기다리는** 구조라 원격 개입이 불가능하다.

| # | 위치 | 현재 동작 | 문제 |
|---|---|---|---|
| A | `run.sh:172` Phase 0 블로커 (`needs_clarification`) | `questions.md` 출력 후 `exit 2` | 루프가 죽음 → spec 보강 후 로컬 재실행 필요 |
| B | `run.sh:188,194` Builder/Critic 의도 질문 (`resolve_intent` 실패) | `exit 2` | 동일 |
| C | `run.sh:216` 최종 머지 승인 | `read -p "...[y/N]"` | 터미널 blocking 입력 대기 |

## 핵심 아이디어

스크립트를 **죽이지 않고**, 같은 프로세스 안에서 **원격 저장소를 폴링**하며 답을 기다린다. 답이 도착하면 함수가 리턴하고 다음 코드로 그대로 이어진다("재개"가 아니라 그냥 함수 리턴). 답을 기다리는 동안 `run.sh` 프로세스는 계속 떠 있어야 한다(폴링 주체).

`REMOTE` 미설정이면 **현재 동작 그대로**(로컬 모드 무손상). 폴링 타임아웃 시에도 **현재 동작으로 안전 폴백**(exit 2 / 보류).

## 컴포넌트

### 1. `olympus-inbox` (신설 private repo)
```
olympus-inbox/            (private)
├── pending/<id>.md       ← run.sh가 질문을 push
└── done/<id>.md          ← 답변 감지 후 run.sh가 이동(자기 commit)
```
- run.sh만 이 repo를 **실시간** pull/push(30s). sj-wiki(launchd 지연·auto-commit 레이스)와 분리해 실시간성·무충돌 확보.
- 사용자는 폰 GitHub 앱/웹으로 `pending/<id>.md`의 `## 답변` 섹션을 채우고 commit.

### 2. `remote.sh` (신설, run.sh가 source)
- `remote_enabled` — `REMOTE=1`인지 확인.
- `remote_ask <id> <type> <title> <bodyfile>` — pending 파일 작성 → commit/push → `remote_notify` 호출 → **blocking 폴링 루프**:
  ```bash
  while true; do
    ( cd "$INBOX_DIR" && git pull -q --ff-only )
    answer=$(extract_answer "pending/$id.md")   # ## 답변 아래, 템플릿 주석 제외
    if [ -n "$answer" ]; then
      ( cd "$INBOX_DIR" && git mv "pending/$id.md" "done/$id.md" \
        && git commit -qm "answered $id" && git push -q )
      printf '%s' "$answer"; return 0
    fi
    waited=$((waited + POLL_SEC))
    [ "$waited" -ge "$POLL_TIMEOUT_SEC" ] && return 3   # 타임아웃 → 안전 폴백
    sleep "$POLL_SEC"
  done
  ```
  - 반환: 답 텍스트(stdout) + 0. 타임아웃 시 3.
  - **충돌 없음**: push 후 파일을 건드리지 않고 사용자 답만 기다리므로 pull은 항상 fast-forward. 답을 읽은 뒤에야 done/ 이동 commit.
- `remote_notify <subject> <body>` — best-effort Gmail SMTP 발송. 실패해도 폴링 코어는 진행.

### 3. `state/human-answers.md` (A·B 답이 쌓이는 파일)
- 블로커/의도질문 답을 append. `roles/metis.md`에 "`state/human-answers.md`에 사람 답이 있으면 요구사항/결정에 반영" 한 줄 추가 → metis 재실행 시 자동 흡수.

## 질문 파일 포맷 (`pending/<id>.md`)
```markdown
---
id: 20260702-153000
type: blocker | intent | approval
created: 2026-07-02T15:30:00
---
## 질문
(questions.md / ask-planner.md 내용, 또는 최종승인 요약)

## 답변
<!-- 아래에 답을 쓰고 commit 하세요. approval이면 y 또는 n -->
```
- **답변 감지** = `## 답변` 섹션에서 템플릿 주석(`<!-- ... -->`)을 제거한 내용이 비어있지 않음.
- `type=approval`이면 그 값이 `y`인지로 승인 판정.

## run.sh 개입 지점별 배선

| 지점 | `REMOTE=1`일 때 |
|---|---|
| A Phase 0 블로커 | `exit 2` 대신 `remote_ask <id> blocker …`(questions.md 본문) → 답을 `human-answers.md`에 append → `metis` 재호출. 타임아웃이면 기존 exit 2. |
| B 의도 질문 | `resolve_intent` 실패 시 `exit 2` 대신 `remote_ask <id> intent …`(ask-planner.md 본문) → `human-answers.md` append → 해당 역할 재투입. 타임아웃이면 exit 2. |
| C 최종 승인 | `read` 대신 `remote_ask <id> approval …`(diff/decisions/open-questions 요약) → 반환값 `y`면 승인, 아니면 보류. `AUTO_APPROVE=1`은 지금처럼 우선. 타임아웃이면 보류. |

## 설정

### `config.sh` (git 추적됨 — 비밀 금지)
- `REMOTE`(기본 미설정/0), `INBOX_DIR`(로컬 클론 경로), `INBOX_REMOTE`(git url: <owner>/olympus-inbox)
- `POLL_SEC=30`, `POLL_TIMEOUT_SEC=21600`(6h)
- `NOTIFY_EMAIL=you@example.com`

### `.env.local` (gitignore됨 — 비밀 전용)
- Gmail SMTP 발신 계정 = **you@example.com** (수신과 동일 = "나에게 보내기"). 앱비밀번호는 `.env.local`에 둔다. 없으면 알림만 스킵, 코어는 정상.
- 발신=수신이라 클라이언트가 대화를 묶거나 "보낸 메일"로 분류할 수 있음 → 제목 `[올림푸스]` 접두사로 필터/검색 용이(아래 알림 절 참조). SMTP 외부 발송이라 받은편지함 배달은 정상.

## 알림 (best-effort, 코어와 분리)
- Gmail SMTP(smtp.gmail.com:587 STARTTLS)로 `you@example.com`에 발송. 제목 예: `[올림푸스] 대기: {type} — {title}`. 본문: 질문 요약 + `olympus-inbox` 링크(`pending/<id>.md`). `Importance: high` + `X-Priority: 1` 헤더로 푸시 우선순위 상향.
- **git이 진실, 메일은 편의**: 발송 실패해도 push/폴링은 정상 진행. 단, 실패는 로그에 크게 남긴다(조용히 삼키지 않음).
- **검증됨(2026-07-02)**: 앱비번으로 실제 테스트 발송 → 폰 받은편지함 메인 탭에 푸시 정상 수신 확인. SMTP 경로·나에게보내기 배달·푸시 모두 OK.

## 타임라인 예시
```
[Mac, run.sh]                        [당신, 폰]
push pending/xxx.md ───────────▶     알림 메일 도착 (you@example.com)
 ↓ pull … 답 없음 (sleep 30s)
 ↓ pull … 답 없음 (sleep 30s)         GitHub 앱: ## 답변에 "y" → commit
 ↓ pull … ★답 감지          ◀────     commit이 origin에 올라감
done/ 이동 + 다음 줄 실행 ──────▶     개발 계속
```

## YAGNI로 제외 (→ Phase 2)
- 실시간 웹훅/양방향 채팅, Supabase 테이블 + Vercel 승인 페이지 → Phase 2.
- 답변 자동 검증/구조화 → 자유텍스트로 충분.
- cron 재기동 기반 복원(프로세스 상시 가동이 싫을 때) → 별도 검토.

## 전제/트레이드오프
- 답을 기다리는 동안 `run.sh`가 **계속 실행 중**이어야 한다(폴링 주체). 무인 실행에서 프로세스 상시 가동 전제 — 사용자 확인됨(OK).
- gh는 본인 계정으로 인증됨(keyring). inbox push/pull에 재사용.
