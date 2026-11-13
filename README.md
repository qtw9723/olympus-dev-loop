# Olympus (올림푸스) — 로컬 다세션 개발 루프 (기획자 + Builder ↔ Critic)

> 이름의 유래: 기획자 **메티스**, 생성자 **헤파이스토스**, 비평가 **모모스**, 라우터 **헤르메스** —
> 이 신들이 사는 곳이 올림푸스다. `spec/<프로젝트>/`에 기획서를 넣고 `bash run.sh` 하면 이들이 알아서 개발한다.

상시 에이전트 환경(예: Hermes Agent)에 올리기 전, **로컬에서 Claude Code 세션들**이 협업해
**기획서(spec/ 폴더의 문서들)만 넣으면 알아서 분석·분해·개발**하는 범용 오케스트레이션 도구.
**대상 프로젝트와 분리**되어 있고(`config.sh`의 `TARGET_REPO`로 지정), 어떤 repo·언어에도 붙일 수 있다.
그라운드 트루스는 LLM 의견이 아니라 **실행되는 게이트(`verify.sh` → 대상 repo의 `VERIFY_CMD`)**.

## 데모 (API 키 없이 1분)
```bash
bash demo/run-demo.sh
```
**실운영이 아니다.** 역할 세션(`claude`)만 `demo/bin/claude`의 스크립트 응답으로 대체하고, `run.sh` 루프·verify 게이트·핸드오프·사람 에스컬레이션은 실제 코드 그대로 실행한다.
시나리오: 구현 역할이 실패하는 테스트를 `verify.sh` 수정으로 가림 → 게이트는 green으로 보고하지만 비평 역할이 diff에서 심판 파일 변경을 적발해 사람에게 에스컬레이션 → 사람이 원복하고 재개 → 진짜 verify green → 머지.
실행 기록을 재생하는 정적 페이지는 `web/index.html`(`python3 demo/build-replay.py`로 생성).

## 역할
- **메티스 (기획자 / Product Owner) — 매 호출 새 세션(무상태)**: 기획서를 **요구사항 분석**(필수)하고,
  다른 세션의 **질문에 답하고**, 합리적이면 **원안과 달라도 변경을 수용·결정**한다.
  기억은 세션이 아니라 durable 파일: `state/requirements.md`(의도=기억), `state/decisions.md`(결정 로그), `state/backlog.md`.
- **헤파이스토스 (Builder)**: 스펙→코드+테스트. 의도 모르면 추측 말고 기획자에게 질문.
- **모모스 (Critic)**: 결함 검사. 칭찬 금지·증거 요구. run.sh 게이트가 남긴 verify 결과를 그라운드 트루스로 삼고, 심판 파일 변경 여부를 diff로 점검.
- **헤르메스 (run.sh)**: (그리스 신 이름이며 아래 Hermes Agent 프로젝트와는 별개다) 루프 제어 — 차례·라운드·예산·질문 라우팅.

## 너는 기획서만 넣는다
`spec/<프로젝트>/` 폴더를 만들어 기획 문서를 넣고 `bash run.sh` 하면, **대상 repo가 `$PROJECTS_DIR/<프로젝트>`에 자동 생성**(git init + 범용 게이트)되고,
기획자가 **항상 먼저 요구사항을 분석**(`requirements.md`)하고
작업으로 분해(`backlog.md`)한 뒤, 작업을 하나씩 Builder↔Critic 루프에 태운다.
모호함은 **합리적 가정으로 그냥 진행**하고 그 의문을 `state/open-questions.md`에 모아 **전체 완료 후 한 번에** 묻는다.
정말 이게 없으면 개발이 불가한 **진짜 블로커일 때만** `state/questions.md`로 멈춘다.

## 구성

```
olympus/              # ← 이 도구(대상 repo와 별개)
├── config.sh             # ★ TARGET_REPO / VERIFY_CMD / 모델 / 예산 (여기만 바꾸면 다른 프로젝트로)
├── prompts.sh            # 세션 프롬프트 조립(참조 기반 최소 주입 — 큰 문서는 경로만, 세션이 직접 읽음)
├── spec/                  # ← 너의 기획 문서들(여러 .md, 입력)
├── roles/
│   ├── metis.md          # 기획자(상시): 요구사항 분석·질문응답·변경수용·작업선택
│   ├── builder.md        # 생성자
│   └── critic.md         # 비평가
├── queue.sh              # ★ 멀티 프로젝트 큐 (add/list/work/migrate — 아래 "멀티 프로젝트 큐" 참고)
├── ui.sh                 # ★ 큐 웹 UI 런처 (ui/ 서버 — 아래 "웹 UI" 참고)
├── ui/                   # 로컬 웹 UI (server.py + queue_ops.py + index.html, 의존성 0)
├── state/                # 런타임 상태 (자동 생성/갱신, git 미추적)
│   ├── queue.json        # 큐의 단일 진실 — 웹 UI가 이 파일로 대기열을 그리고 조작한다
│   └── <프로젝트>/        # 프로젝트별 완전 격리 (아래 파일들이 프로젝트마다 한 벌씩)
│       ├── requirements.md # 기획자의 요구사항 분석 = 의도의 "기억"
│       ├── decisions.md      # 기획자가 수용한 변경/결정 로그
│       ├── backlog.md        # 분해된 작업 목록(todo/doing/done)
│       ├── task.md           # 현재 작업 + 수용 기준
│       ├── progress.md       # 현재 작업 진행 저널(토큰 대기 등 중단-재개용, 작업 전환 시 초기화)
│       ├── ask-planner.md    # Builder/Critic → 기획자 의도 질문 큐
│       ├── findings.md       # Critic → 기획자 범위밖 결함 큐(자율 트리아지)
│       ├── questions.md      # 기획자 → 사람: 진짜 블로커만(개발 멈춤)
│       ├── open-questions.md # 기획자 → 사람: 가정으로 진행한 의문(끝에 한 번에)
│       ├── critic-feedback.md# 비평가 지적
│       ├── verify.txt        # verify 실행 기록(심판, 런타임)
│       └── handoff.json      # 차례·라운드·status
├── verify.sh             # 게이트: (TARGET_REPO에서) VERIFY_CMD → state/verify.txt
└── run.sh                # 오케스트레이터(기획자→Builder↔Critic 자동 루프)
```

대상 repo(예: notepad)는 **건드리지 않는 별개 경로**다. 세션은 `TARGET_REPO`의 코드를 작업하고,
상태/스펙은 이 `olympus/` 안에 둔다.

## 흐름 (5단계 파이프라인)

```
spec/   ─▶ [기획자] 요구사항 분석(필수) → requirements.md
              ├─ 진짜 블로커만 → questions.md 쓰고 멈춤(보강 후 재실행)
              ├─ 그 외 모호함 → 가정으로 진행 + open-questions.md에 누적
              └─ 분해 → backlog.md + 첫 task.md
                    │
        ┌───────────┘  각 작업마다:
        ▼
   [Builder] 구현+테스트 ──(의도 모르면)──▶ ask-planner.md → [기획자]가 답(requirements 갱신)
        │                                              ↑
        ▼  verify.sh(심판)                              │
   [Critic] 결함검사+verify 결과 대조·심판 무결성 점검 ──(의도 의심)─────────┘
        ↑ 결함 → Builder            └ green+결함없음 → status=green
        └──────────────────────────────────┘
   green → [기획자] 다음 작업 → … → 전부 done → 사람 최종 승인(전체 1회, 머지)
```

`status` 값: `pending / needs_clarification / ready / reviewing / needs_intent / green / all_done`.

## 변경 수용 (원안과 달라도)
Builder/Critic의 합리적 대안이나 분석 중 더 나은 길이 보이면 **기획자가 결정해 수용**한다.
수용하면 `decisions.md`에 "무엇을·왜·원안과 차이"를 남기고 `requirements.md`/`backlog.md`를 갱신한다.
범위를 크게 바꾸는 결정은 `⚠️사람확인요`로 표시해 사람이 사후 검토.

## 실행 방법

### 0. 설정 (1회)
`config.sh`에서 대상과 검증 명령을 지정:
- `TARGET_REPO="/Users/you/projects/notepad"`
- `VERIFY_CMD="npm run verify"`  (Python이면 `"ruff check . && mypy . && pytest -q"` 식)

### A. 자동 — `bash run.sh`
1. `spec/<프로젝트>/` 폴더를 만들어 기획 문서(`*.md`)를 넣는다. (대상 repo·게이트는 폴더명으로 자동 생성)
2. `bash run.sh` 실행. (같은 프로젝트를 처음부터 다시면 먼저 `bash reset.sh <프로젝트>`)
3. **진짜 블로커**가 있을 때만 `questions.md`로 멈춤 → spec 보강 후 재실행. 그 외 모호함은 가정으로 진행.
4. 작업은 green 되면 **승인 없이 바로 다음 작업**으로. **전체 백로그가 끝난 뒤 1회만** 최종 머지 승인을 묻는다(`AUTO_APPROVE=1`이면 생략).
- 환경변수로도 덮어쓰기 가능: `TARGET_REPO`, `VERIFY_CMD`, `MAX_ROUNDS`, `*_MODEL`, `AUTO_APPROVE`.
- 기획자 상시성: `run.sh`는 `--session-id`/`--resume`로 기획자 세션을 이어붙인다(환경에서 안 되면 durable 파일로 맥락 유지).
- 세션은 `cd TARGET_REPO` + `--add-dir <olympus>`로 실행 — 코드는 대상에, 상태는 olympus에.
- ⚠️ `claude` CLI 플래그는 버전에 맞게 조정. 처음엔 B로 한 바퀴 검증 권장.

### B. 수동(터미널 여러 개) — 가장 확실, "상시 기획자"를 진짜로 켜둠
대상 repo에서 claude를 띄우고 이 olympus을 add-dir로 물린다:
```
cd <TARGET_REPO> && claude --add-dir <olympus 경로>
```
- 터미널1(상시): 첫 메시지로 `<olympus>/roles/metis.md`를 주고 "spec/ 문서들 분석·분해해줘". **이 창은 끄지 말 것**(질문 응답 담당).
- 터미널2: `roles/builder.md`. 터미널3: `roles/critic.md`.
- `state/handoff.json`의 `turn`/`status`로 차례를 넘긴다. 의도 질문은 `state/ask-planner.md` ↔ 기획자 창.

## 멀티 프로젝트 큐 (queue.sh)

작은 프로젝트 여러 개를 등록해두면 **순차로 알아서 소화**한다. 상태는 `state/<프로젝트>/`로 격리, 큐는 `state/queue.json` 하나가 단일 진실이다(웹 UI도 이 파일 하나로 대기열을 그리고 조작한다 — 아래 "웹 UI").

```bash
bash queue.sh add mindboard              # 등록 (spec/mindboard/ 필요, 기본 mode=auto)
bash queue.sh add notepad --mode lite    # 라이트 모드 강제
bash queue.sh list                       # 큐 상태 표
bash queue.sh work                       # 워커: 큐가 빌 때까지 하나씩 실행 → 종합 메일 1통
bash queue.sh migrate <프로젝트>          # (1회) 구 단일 state 레이아웃 이행
```

- **모드**: `auto`(기본)면 메티스가 분석 직후 규모를 판정해 lite/full 결정. `lite`는 분해 1~2작업 + 라운드 상한 3 — Critic·verify 게이트는 그대로.
- **블로커여도 큐는 멈추지 않는다**: 그 항목만 `paused(blocker)`로 눕히고(질문은 알림 메일) 다음 프로젝트 진행. 답변 후 항목 status를 `queued`로 되돌리면 재개(M0 재개 가드가 이어받음).
- **UI/사람의 조작 계약(queue.json)**: `queued/paused` 항목은 추가·삭제·순서변경(배열 순서=우선순위)·mode 변경 가능. `running` 항목엔 `request: "pause"|"cancel"`만 쓰면 워커가 역할 턴 사이에 존중한다. status/progress/result는 워커 소유.
- **워커가 죽으면**: 다음 `queue.sh work`가 스테일 running 항목을 `paused(stale)`로 회수 후 계속.
- 실패(`failed:verify`/`failed:crash`)도 항목만 기록하고 다음으로 — 전체 큐를 막지 않는다.
- **구버전에서 진행 중이던 실행의 재시작**: 실행을 중지하고 이 버전을 풀 받아 `bash run.sh` 하면, 루트 `state/`에 남은 구 레이아웃을 감지해 `state/<프로젝트>/`로 **자동 이행**하고 M0 재개 가드가 이어받는다(재분석 없음). 단 spec 폴더가 여러 개라 프로젝트를 추정할 수 없으면 안전하게 중단하니 `PROJECT=<이름> bash run.sh`로 지정해 재시작할 것.

### 원클릭 시작 (Olympus.app / start.command)

**`Olympus.app` 더블클릭** 한 번으로: UI 서버 기동 → 브라우저 열기 → **큐 상시 감시**.
이후 웹 UI에서 등록하는 항목은 몇 초 안에 자동으로 실행된다. 중지는 열린 터미널 창에서 Ctrl+C.
Dock이나 /Applications에 복사해도 되고(저장소 밖이면 `~/projects/olympus`를 찾는다), Spotlight에서 "Olympus"로도 뜬다.
아이콘 원본은 `assets/icon.svg` — 앱은 결국 터미널로 `start.command`를 여는 래퍼라, 터미널 파일 실행이 편하면 `start.command` 더블클릭도 같다.

```bash
bash queue.sh work            # 1회 소진: 큐를 비우면 종료
bash queue.sh work --watch    # 상시 감시: 큐가 비어도 대기, 등록되면 자동 실행 (--watch 10 = 10초 간격)
```

터미널 사용자는 alias 추천: `alias olympus='bash ~/projects/olympus/start.command'`

### 로컬 세팅 자동 적용 (setup.sh)

기기별 로컬 세팅(터미널 alias 등)은 git으로 따라가지 않으므로, **세팅 버전**으로 관리한다:
저장소의 `setup.sh`가 요구 버전(`SETUP_VERSION`)을, 각 기기의 `state/setup.version`(git 미추적)이 적용된 버전을 기록한다.
`run.sh`/`queue.sh work` 시작 시 자동 비교해 **모자란 단계만 순서대로 적용**하니, 다른 기기는 풀 받고 실행만 하면 된다.

- 수동 적용: `bash setup.sh` · 끄기: `OLYMPUS_SETUP=0`
- 새 세팅 추가법: `SETUP_VERSION` +1 하고 `setup_step_<N>` 함수 추가(멱등 필수, 플랫폼 전용은 uname 가드 — Windows는 Git Bash/WSL 가정)
- 단계가 실패하면 마커가 그 앞에 멈춰 **다음 실행 때 실패한 단계부터 재시도**된다
- v1: 터미널 alias `olympus` 등록(zsh→~/.zshrc, 그 외→~/.bashrc. 이미 있으면 건드리지 않음)

### 웹 UI (ui.sh)

큐를 브라우저로 보고 조작한다. 의존성 없음(Python3 표준라이브러리), 127.0.0.1 전용.

```bash
bash ui.sh            # 포그라운드 실행 — http://127.0.0.1:8765 (포트 변경: bash ui.sh 9000)
bash ui.sh autostart  # 백그라운드 멱등 기동(이미 떠 있으면 no-op) — run.sh/queue.sh work가 시작 시 자동 호출
bash ui.sh stop       # autostart로 띄운 서버 종료 (state/ui.pid 기준)
```

`bash run.sh`·`bash queue.sh work`를 실행하면 UI 서버가 **자동으로 함께 뜬다**(백그라운드, 로그는 `state/ui.log`).
끄려면 `OLYMPUS_UI=0`, 포트 변경은 `OLYMPUS_UI_PORT=<포트>`.

- **보기**: 대기열(상태 배지·진행바·result), 워커 상태(idle/실행 중/스테일 배지), 항목 클릭 → handoff.json + 최근 로그 tail. 실행 중이면 상단에 **실행 중 세션 패널** — 역할(turn)·라운드·현재 작업·라이브 로그(2초 갱신, 아래 고정 스크롤).
- **조작**: 등록(spec/ 스캔 드롭다운)·삭제·↑↓ 순서변경·mode 변경(queued), 일시정지/취소 요청(running — 역할 턴 사이에 반영), 재개(paused→queued).
- **결정 패널**: 블로커로 멈춘 항목의 질문(questions.md)이 대기열 위에 뜬다 — 답을 적고 [답변하고 재개]를 누르면 `state/<프로젝트>/human-answers.md`에 기록되고 자동 재개, 재개된 기획자가 답을 최우선 반영한다. 가정으로 진행 중인 열린 질문(open-questions.md)도 참고용으로 표시. 최종 머지 승인 y/n은 아직 터미널/메일 소유(후속).
- 조작은 전부 시맨틱 API를 거쳐 **필드 소유권 계약을 서버가 강제**한다 — 워커 소유 필드(status/progress/result 등)는 UI로 변경 불가, 락은 queue.sh와 같은 mkdir 락. 워커 실행 자체는 여전히 터미널 소유(`bash queue.sh work`).

### 안전 중지 (진행 중 실행 멈추기)

실행 중인 올림푸스는 언제든 중단해도 안전하다 — 진행 상태는 전부 durable 파일(`state/`)에 있고, 재시작하면 M0 재개 가드 + 진행 저널(progress.md)이 중단 지점부터 이어받는다. 최악의 경우도 "중단 순간 돌던 역할 세션 하나의 부분 작업"만 다시 한다.

터미널에서 돌고 있으면 **그 터미널에서 Ctrl-C** 한 번이면 끝(프로세스 그룹 전체에 전달됨). 백그라운드/다른 세션이면:

```bash
# 1) 오케스트레이터 확인 (queue.sh work가 run.sh를 자식으로 거느린다)
pgrep -fl 'bash.*(queue|run)\.sh'

# 2) 오케스트레이터부터 중지 — 다음 역할 세션 스폰을 막는다 (TERM이면 충분, -9 불필요)
kill <위에서 확인한 PID>        # queue.sh work가 있으면 그것부터, 그다음 run.sh

# 3) 남은 자식(역할 세션·tee) 확인 후 있으면 개별 kill
pgrep -lP <run.sh PID>

# 4) 중지 확인
pgrep -fl 'bash.*(queue|run)\.sh' || echo "중지 완료"
```

- ⚠️ **`pkill -f claude` 금지** — 역할 세션 외의 claude(예: 이 중지 작업을 시키고 있는 Claude Code 세션 자신, 다른 창의 세션)까지 죽는다. 반드시 위처럼 run.sh의 **자식 PID를 확인해 개별로** 정리한다.
- 어디까지 진행했는지는 실행 로그로 확인: `tail -30 state/*/runs/run-*.log` (구버전 레이아웃이면 `state/runs/run-*.log`).
- verify가 돌던 중이었다면 대상 repo에 잔여 프로세스(npm/pytest 등)가 있을 수 있으니 `pgrep -fl <VERIFY_CMD 키워드>`로 한 번 확인.
- 토큰 한도 대기(resilience) 중 멈추는 것도 동일 — sleep 중인 run.sh를 kill 하면 된다.

중지 후 재시작: `git pull` → `bash run.sh` (위 "구버전에서 진행 중이던 실행의 재시작" 참고).

## 원격 결정 (Phase 1: Git 브리지)
무인 실행 중 사람 개입(블로커·의도질문·최종승인)을 폰에서 처리:
1. 1회: `gh repo create <owner>/olympus-inbox --private`, `.env.local`에 SMTP 앱비번.
2. `REMOTE=1 bash run.sh` — 개입 시 `olympus-inbox/pending/<id>.md` push + you@example.com 알림.
3. 폰 GitHub 앱에서 `## 답변` 섹션 채우고 commit → run.sh가 30s 폴링으로 감지해 계속.
- 답 대기 상한 `POLL_TIMEOUT_SEC`(기본 6h) 초과 시 로컬 중단으로 안전 폴백.
- `REMOTE` 미설정이면 기존 로컬 동작 그대로.

### 최종 승인만 Gmail 답장으로 (경량 경로)
잦은 최종 머지 승인(yes/no 하나)은 GitHub 파일 편집 대신 **메일 답장**으로 처리한다(`APPROVE_VIA_EMAIL=1`, 기본 켜짐).
- 승인 요청 메일이 오면 **답장 첫 줄에 `y`(보류 `n`)만** 적어 보낸다 → run.sh가 발송과 **같은 Gmail 계정 IMAP**(SMTP 앱비번 재사용)을 폴링해 감지.
- 견고화: 제목 토큰 `‹OLY-<id>›`으로 run 매칭 / **인용부 이전 첫 줄만** whole-line 파싱(인용 속 키워드 무시) / `APPROVE_FROM`(기본=발송계정) 발신자만 인정(위조 차단).
- 블로커·의도질문은 그대로 GitHub 경로. IMAP 비밀 없음/접속 실패면 **자동으로 GitHub 승인 경로로 폴백**. `APPROVE_VIA_EMAIL=0`이면 최종 승인도 GitHub로.

## 지속 사용 (여러 프로젝트·반복)
이 도구는 한 번 쓰고 버리는 게 아니다. **`state/`는 런타임(git 미추적)**이고, 도구(roles·스크립트·README)만 추적한다.
- **새 작업 시작**: `bash reset.sh <프로젝트>`로 그 프로젝트의 `state/<프로젝트>/`만 초기화 → `spec/`에 새 기획서 → `bash run.sh`. (state 없으면 run.sh가 자동 초기화)
- **다른 프로젝트에 붙이기**: `config.sh`를 고치지 않고 **환경변수로 그때그때 지정** 가능 —
  `TARGET_REPO=/path/to/repo VERIFY_CMD="npm run verify" bash run.sh`. (대상별로 `config.sh`를 복제해 둬도 됨)
- **여러 대상 병행**: 상태가 `state/<프로젝트>/`로 격리되므로 클론 없이 그대로 — 순차 소화는 큐(`bash queue.sh work`)로.
- `state/<프로젝트>/runs/`에 실행 로그가 쌓이므로 무인 실행 이력을 사후 추적할 수 있다.

## Hermes Agent로 옮길 때의 매핑
- 기획자=메티스, Builder=헤파이스토스, Critic=모모스, run.sh 루프=라우터(헤르메스 역할).
- `state/`(파일 공유) → Hermes Agent 쪽에선 외부 영속 상태(예: Supabase)로 승격.
- `verify.sh`/`config.sh` → 대상·언어만 바꾸면 그대로 재사용(어댑터).
- Phase 3(요구사항 전부 끝난 뒤 추가기능 제안·교차검증)은 미구현 — 다음 확장 후보.
```

## 토큰 소진 자동 대기·재개

무인 실행 중 Claude Code 사용량 한도(5시간/주간)에 걸리면, 올림푸스가 **감지→리셋까지 대기→그 자리에서 자동 재개**한다(`resilience.sh`). 사람 개입 불필요.

- 감지: `claude` 출력의 `You've hit your` 패턴(종료코드 미의존).
- 대기: 리셋시각을 best-effort 파싱해 그때까지 대기하되, 파싱 실패해도 `TOKEN_RETRY_SEC`마다 경량 프로브(`claude -p ok`)로 재확인 → 자기교정. 대기 중 토큰 비용 ≈0(한도 거부는 추론 전 게이트, 토큰 0).
- 429/529(일시 용량)는 CLI 워치독(`CLAUDE_CODE_RETRY_WATCHDOG=1`, run.sh가 자동 export)에 위임.
- 크로스플랫폼: macOS·Windows(Git Bash/WSL) 동일 동작.

노브(config.sh 또는 env): `TOKEN_WAIT`(기본 1, 0=끄기), `TOKEN_RETRY_SEC`(1200), `TOKEN_RESET_BUFFER_SEC`(60), `TOKEN_WAIT_CHUNK_SEC`(1800), `TOKEN_MAX_WAIT_SEC`(0=무제한).

**한계**: 대기는 실행 중인 `run.sh` 프로세스 안에서 일어난다. `sleep`은 벽시계 기준이라 잠자기→깨어남은 견디지만, **터미널을 닫거나 프로세스가 죽으면(로그아웃·재부팅) 유실**된다 — 이 경우 `bash run.sh`를 다시 실행하면 durable 상태(state/, 작업 브랜치 커밋)에서 이어진다. 프로세스가 죽어도 자동 재실행하는 외부 supervisor는 후속 과제(B안).

## 출처와 영감
[Hermes Agent](https://github.com/NousResearch/hermes-agent)(Nous Research, MIT 라이선스)를 개인 비서로 운영하면서 구상한
"생성자↔비평가 코드 자가개선 루프"를, 상시 서버 없이 로컬에서 먼저 검증하려고 만든 독립 구현이다.
오케스트레이션은 순수 Bash와 `claude -p` 헤드리스 호출로 새로 작성했다.
