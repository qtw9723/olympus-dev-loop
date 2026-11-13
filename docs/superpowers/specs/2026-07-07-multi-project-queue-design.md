# 올림푸스 멀티 프로젝트 큐 — 설계

날짜: 2026-07-07
상태: 구현 완료 (2026-07-07, 같은 브랜치)
브랜치: feat/multi-project-queue

> **구현 중 조정 3건** (설계 의도는 동일, 수단만 변경):
> 1. **락**: macOS에 `flock`이 없어 mkdir 락(`state/queue.lock/` 디렉터리 + pid, 스테일 자동 회수)으로 구현.
> 2. **모드 변수명**: run.sh의 기존 `MODE`(greenfield/brownfield)와 충돌해 `OLYMPUS_MODE`로 명명.
> 3. **마이그레이션**: 최초 실행 시 자동 감지·이동 대신, 구 레이아웃 감지 시 add/work를 가드(exit 2)하고
>    `bash queue.sh migrate <프로젝트>` 명시 실행으로 이행(프로젝트명 오추정 방지). 실 데이터는 state/notepad/로 이행 완료.

## 목적

올림푸스를 "한 번에 한 프로젝트" 도구에서 **다수의 소형 프로젝트를 순차 소화하는 큐 기반 오케스트레이터**로 확장한다.
핵심 제약: 추후 **로컬 웹 UI**가 파일을 직접 읽고 써서 대기열·작업을 시각화하고 **조작(등록·순서변경·일시정지·취소)** 할 수 있어야 한다. 따라서 상태 파일 설계가 곧 UI의 API다.

## 확정된 요구사항

| 항목 | 결정 |
|---|---|
| UI 역할 | 모니터링 + 큐 조작(등록·순서변경·정지·취소) |
| UI 위치 | 로컬 웹앱 — 파일시스템 직접 읽기/쓰기, 동기화 계층 없음 |
| 동시성 | 순차 1워커 (워커 N개 확장이 가능한 구조로만 설계) |
| 라이트 모드 판정 | 큐 항목 `mode: auto\|lite\|full` 필드, auto면 메티스가 분석 직후 판정 |
| 접근법 | 파일 기반 큐 + 프로젝트별 상태 디렉터리 (SQLite·심링크 트릭 기각) |

## 1. 파일 레이아웃

```
olympus/
├── state/
│   ├── queue.json          # 큐의 단일 진실 = UI의 API
│   ├── queue.lock          # flock용 락 파일
│   └── <프로젝트>/          # 프로젝트별 완전 격리 (기존 state/* 전부가 이 아래로)
│       ├── handoff.json    # turn/round/status/task (기존 구조 그대로)
│       ├── requirements.md, decisions.md, backlog.md, task.md, progress.md
│       ├── ask-planner.md, findings.md, questions.md, open-questions.md
│       ├── critic-feedback.md, human-answers.md, builder-notes.md
│       ├── usage.tsv, verify.txt
│       └── runs/run-*.log
└── spec/<프로젝트>/         # 기존 그대로 (입력)
```

## 2. `queue.json` 스키마 (v1)

```json
{
  "version": 1,
  "worker": { "pid": 4821, "current_id": "q-001", "heartbeat_at": "2026-07-07T10:32:00+09:00" },
  "items": [
    {
      "id": "q-001",
      "project": "notepad",
      "mode": "auto",
      "mode_resolved": "lite",
      "status": "running",
      "request": null,
      "progress": { "done": 2, "total": 5, "current_task": "T3 — ..." },
      "enqueued_at": "2026-07-07T09:00:00+09:00",
      "started_at": "2026-07-07T10:00:00+09:00",
      "finished_at": null,
      "result": null,
      "paused_reason": null
    }
  ]
}
```

- 배열 순서 = 우선순위. UI는 배열을 재배열해 순서를 바꾼다.
- `status`: `queued | running | paused | done | failed | cancelled`
- `request`: UI → 워커 요청 채널. `running` 항목에만 `"pause"` 또는 `"cancel"`을 쓴다.
- `mode`: `auto | lite | full`. `mode_resolved`: auto였을 때 메티스가 실제 판정한 값.
- `result`(종료 시): `"green" | "failed:verify" | "failed:crash" | "blocked:<질문 한 줄 요약>"`
- `progress`: 워커가 마일스톤 훅에서 갱신 — UI가 backlog.md를 파싱하지 않고 이 파일 하나로 대기열 화면 전체를 그린다. 상세는 `state/<프로젝트>/`를 읽는다.

### 동시 쓰기 규칙 (필드 소유권 계약)

- 모든 쓰기: `flock state/queue.lock` 획득 → 임시파일 작성 → `mv` (원자적 교체).
- **UI가 쓰는 것**: `queued/paused` 항목의 추가·삭제·배열 순서·`mode` 변경, `paused → queued` 되돌리기(재개), 그리고 `running` 항목의 `request` 필드만.
- **워커가 쓰는 것**: `status`, `progress`, `mode_resolved`, `result`, `paused_reason`, 타임스탬프, `worker` 블록.
- 두 주체가 같은 필드를 다투지 않으므로 락 + 원자적 쓰기로 충분하다 (1워커 + 1UI 전제).

## 3. 워커 (`queue.sh`)

CLI:
- `bash queue.sh add <프로젝트> [--mode lite|full]` — `spec/<프로젝트>/` 존재 확인 후 항목 추가 (기본 auto)
- `bash queue.sh list` — 큐 상태 표 출력
- `bash queue.sh work` — 워커 루프

워커 루프:
1. flock으로 첫 `queued` 항목 클레임 → `running` + `worker` 블록(pid, current_id, heartbeat) 갱신
2. `PROJECT`·`QUEUE_ITEM_ID`·`MODE` 환경변수로 `run.sh` 호출
3. 종료 후 결과 기록: handoff status `all_done` + verify green → `done/green`, 블로커 → `paused/blocked:*`, 그 외 비정상 → `failed:*`
4. 다음 `queued` 항목으로. 큐가 비면 종합 알림 1통 후 종료.

역할 턴 사이 heartbeat 갱신. **스테일 클레임 회수**: `heartbeat_at`이 임계(예: 30분)를 넘고 해당 pid가 죽어 있으면, **차기 워커가** `running` 항목을 `paused (paused_reason=stale)`로 복구한다. (UI는 스테일을 표시만 하고 status를 직접 고치지 않는다 — 필드 소유권 계약 유지.)

## 4. `run.sh` 및 기존 스크립트 변경

- `STATE_DIR="$PIPELINE_DIR/state/$PROJECT"` 도입. `run.sh, prompts.sh, verify.sh, milestones.sh, finalize.sh, resilience.sh, remote.sh, gitops.sh, reset.sh`의 `$PIPELINE_DIR/state` 하드코딩(46곳)을 `$STATE_DIR`로 치환. `verify.sh`는 단독 실행도 가능해야 하므로 `PROJECT` 인자/환경변수를 받는다.
- `prompts.sh`는 세션에 `$STATE_DIR`를 상태 디렉토리로 주입(현 21행). roles/*.md의 `state/xxx.md` 언급은 "상태 디렉토리 아래의 xxx.md"로 문구 정리.
- **체크포인트**: 큐 모드(`QUEUE_ITEM_ID` 존재)일 때 각 역할 세션 호출 직전에 자기 항목의 `request` 확인 — `pause`면 `paused` 기록 후 정상 종료, `cancel`이면 `cancelled` 기록 후 종료. UI 조작은 역할 턴 단위로 반영된다.
- **블로커 처리**: 큐 모드에서는 `questions.md` 블로커 시 사람을 기다리지 않고 해당 항목만 `paused (blocker)` + 알림 발송 후 워커는 다음 항목으로 진행. 답변 후 UI(또는 CLI)에서 `queued`로 되돌리면 기존 M0 재개 가드가 재분석 없이 이어간다.
- **하위 호환**: `bash run.sh` 단독 실행은 기존대로 동작(큐 없이 spec 첫 폴더 선택). 단 state 경로는 프로젝트별 경로를 쓴다.
- `reset.sh <프로젝트>` — 해당 프로젝트 state만 초기화. 인자 없이 실행하면 안내 후 종료(전역 삭제 방지).

### 마이그레이션 (일회성)

`queue.sh` 최초 실행 시 `state/handoff.json`이 루트에 있으면 구버전 레이아웃으로 판단, `state/*`를 `state/notepad/`(당시 프로젝트명)로 이동한다. `state/runs/`도 함께 이동.

## 5. 라이트 모드

- 전달 경로: 큐 항목 `mode` → `run.sh` `MODE` 환경변수 → 메티스 프롬프트.
- **full**: 현행 그대로 (MAX_ROUNDS=6).
- **lite**: 메티스 M0에 라이트 지시(요구사항 분석 간결화, 백로그 1~2개 작업으로만 분해) + MAX_ROUNDS=3.
- **auto**: 메티스가 M0 분석 끝에 판정(기준 예시: 예상 작업 3개 이하·단일 모듈이면 lite)해 `handoff.json`에 `mode` 필드로 기록 → run.sh가 읽어 라운드 상한 적용 + `queue.json`의 `mode_resolved`에 미러링.
- **Critic·verify 게이트는 라이트에서도 유지** — 품질 판정은 그대로, 의식(분해·라운드)의 양만 줄인다.

## 6. 알림

- 기존 프로젝트별 마일스톤 알림(분석 완료/진행 n/N/전체 완료) 유지 — 제목에 이미 `$PROJECT` 포함.
- 추가: **큐 드레인 종합 메일 1통** — 항목별 `project / mode_resolved / result / 소요·토큰(usage.tsv 합산)` 표.

## 7. 에러 처리 요약

| 상황 | 항목 상태 | 큐 |
|---|---|---|
| verify 최종 실패 | `failed` (`failed:verify`) | 다음 항목 진행 |
| run.sh 크래시 | `failed` (`failed:crash`) | 다음 항목 진행 |
| 블로커 질문 | `paused` (`blocker`) + 알림 | 다음 항목 진행 |
| UI pause 요청 | 체크포인트에서 `paused` | 다음 항목 진행 |
| UI cancel 요청 | 체크포인트에서 `cancelled` | 다음 항목 진행 |
| 워커 사망(스테일) | `running → paused (stale)` | 차기 워커가 회수 |

## 8. 테스트

`test/`에 추가 (기존 테스트 방식 준수):
1. 큐 연산 유닛: add/list/claim, 원자적 쓰기, 필드 소유권(요청-존중 시나리오)
2. lite 전파: mode=lite → MAX_ROUNDS=3·메티스 프롬프트에 라이트 지시 포함
3. 격리 e2e: 2개 미니 spec을 큐로 순차 실행 → 상태 교차 오염 없음, 각자 green
4. 마이그레이션: 구 레이아웃 감지 → state/<프로젝트>/ 이동 확인
5. 스테일 회수: 죽은 pid + 오래된 heartbeat → paused 복구

## 범위 밖 (명시)

- 웹 UI 자체 구현 (이번 설계는 파일 계약까지만)
- 병렬 N워커 (구조만 열어둠 — 클레임 방식·프로젝트별 state 격리로 가능)
- 원격(폰) 접근 — 기존 원격 결정 브리지와의 통합은 후속
