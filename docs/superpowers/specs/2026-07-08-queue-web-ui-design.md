# 올림푸스 큐 로컬 웹 UI — 설계

날짜: 2026-07-08
상태: 설계 확정
브랜치: feat/queue-web-ui
선행 스펙: 2026-07-07-multi-project-queue-design.md (queue.json 계약 v1 — 본 UI는 그 계약의 소비자)

## 목적

`state/queue.json`을 단일 진실로 삼아 대기열을 **시각화**하고 **조작(등록·삭제·순서변경·모드변경·일시정지·취소·재개)** 하는 로컬 웹 UI. 선행 스펙의 "상태 파일 설계가 곧 UI의 API" 계약을 그대로 구현한다.

## 확정 결정

| 항목 | 결정 | 근거 |
|---|---|---|
| 스택 | Python3 표준라이브러리 `http.server` 단일 서버 + 정적 HTML/바닐라 JS | 저장소에 이미 Python 사용(notify.py, inbox_imap.py), 의존성 0. Node/SPA는 bash 저장소에 과함 → 기각. 순수 정적 파일은 브라우저가 로컬 파일을 못 써서 기각 |
| 조작 방식 | raw JSON 쓰기 금지 — **시맨틱 API 엔드포인트만** | 필드 소유권 계약 위반을 서버 계층에서 원천 차단 |
| 락 | queue.sh와 동일한 mkdir 락(`state/queue.lock/` + pid, 스테일 pid 회수) + tmp→mv 원자적 쓰기 | bash 워커와 같은 프로토콜이어야 상호 배제가 성립 |
| 바인딩 | 127.0.0.1 전용, 기본 포트 8765, 인증 없음 | 로컬 도구 |
| 폴링 | 2초 간격 GET (푸시/웹소켓 없음) | 1워커+1UI 규모에 충분, YAGNI |
| 스테일 표시 | worker.pid 사망 또는 heartbeat 30분 초과 → 배지 표시만 | 선행 계약: UI는 스테일을 표시만, status 복구는 차기 워커 소유 |

## 파일 구성

```
olympus/
├── ui.sh                 # 런처: exec python3 ui/server.py "$@" (기존 최상위 .sh 진입점 컨벤션)
├── ui/
│   ├── server.py         # HTTP 서버 + 라우팅 (표준라이브러리만)
│   ├── queue_ops.py      # 큐 조작 로직 — 락/원자적쓰기/소유권 검증. CLI로도 실행 가능(테스트용)
│   └── index.html        # 단일 페이지 (CSS/JS 인라인)
└── test/ui_ops_test.sh   # 기존 helpers.sh 컨벤션의 bash 테스트
```

`queue_ops.py`를 서버에서 분리한 이유: 순수 함수 모듈이어야 bash 테스트가 CLI로 직접 검증 가능하고, 서버(HTTP 계층)와 조작 로직(소유권 계약)을 독립적으로 이해할 수 있다.

## API (모두 JSON)

| 메서드/경로 | 동작 | 소유권 가드 |
|---|---|---|
| GET `/api/queue` | queue.json 전체 + `stale`(파생, pid 사망/heartbeat 30분 초과) + `projects`(spec/ 하위 디렉터리 목록, `_README.md` 제외) | 읽기 전용 |
| POST `/api/add` `{project, mode}` | 항목 추가 (id 생성: `q-<ts>-<rand>`, queue.sh와 동일 형식) | `spec/<project>/` 존재 확인, mode는 auto\|lite\|full |
| POST `/api/remove` `{id}` | 항목 삭제 | `running` 항목은 409 거부 |
| POST `/api/reorder` `{order: [id...]}` | items 배열을 주어진 순서로 재배열 | id 집합이 현재와 완전 일치해야 함(추가/누락 시 409). 순서만 변경, 내용 불변 |
| POST `/api/mode` `{id, mode}` | mode 변경 | `queued/paused`만 허용 |
| POST `/api/resume` `{id}` | `paused → queued` (paused_reason·request는 null로) | `paused`만 허용 |
| POST `/api/request` `{id, action}` | `request` 필드에 `pause`\|`cancel` 기록 | `running`만 허용 |
| GET `/api/detail?project=` | `state/<프로젝트>/handoff.json` + 최신 `runs/run-*.log` 마지막 50줄 | 읽기 전용. 경로는 프로젝트명 화이트리스트(영숫자·`-`·`_`)로 검증 |

- 모든 쓰기는 락 획득 → 검증 → tmp 작성 → `mv` → 락 해제. 검증 실패는 409 + 사유 메시지.
- 워커 소유 필드(status/progress/mode_resolved/result/타임스탬프/worker)는 위 엔드포인트로 절대 변경 불가 — resume의 status 전이와 paused_reason 정리는 선행 계약이 UI에 허용한 유일한 예외.

## 화면 (단일 페이지)

1. **워커 상태 바** — idle(worker=null) / running(pid·현재 항목·heartbeat 경과) / **stale 배지**(빨강, 표시만)
2. **등록 폼** — 프로젝트 드롭다운(spec/ 스캔, 대기·실행 중인 프로젝트는 표기) + mode 선택 + 등록 버튼
3. **대기열 목록** — 배열 순서대로. 항목마다:
   - 상태 배지(queued 회색 / running 파랑 / paused 노랑 / done 초록 / failed·cancelled 빨강·회색), mode(`auto→lite` 병기), progress 바(`done/total` + current_task), result, paused_reason
   - 액션(상태별): queued → ↑/↓/mode/삭제 · running → 일시정지/취소 요청(request 대기 중이면 "요청됨" 표시) · paused → 재개/삭제 · 종료 상태 → 삭제
   - 클릭 → 상세 패널(handoff.json 요약 + 최근 로그 tail, 접이식)
4. 2초 자동 새로고침(fetch). 조작 직후 즉시 재조회. 오류는 상단 토스트로 표시.

순서 변경은 ↑/↓ 버튼(드래그앤드롭 기각 — 바닐라 구현 복잡도 대비 이득 없음).

## 에러 처리

| 상황 | 처리 |
|---|---|
| 락 획득 실패(10초) | 503 + "큐 락 획득 실패" — UI 토스트 |
| 소유권/상태 가드 위반 | 409 + 사유 — UI 토스트 (예: "실행 중 항목은 삭제 불가 — 취소 요청을 쓰세요") |
| queue.json 없음 | 읽기는 빈 큐 반환, 쓰기는 queue.sh와 동일하게 초기화 후 진행 |
| reorder 경합(폴링 사이 워커가 항목 변경) | id 집합 불일치 → 409, UI가 재조회 후 사용자 재시도 |

## 테스트 (test/ui_ops_test.sh)

1. add → queued 생성, spec 없는 프로젝트 거부, 잘못된 mode 거부
2. 소유권 가드: running 삭제 거부 / running 아닌 항목 request 거부 / queued에 resume 거부
3. reorder: 순열 적용, id 누락·추가 시 거부
4. resume: paused→queued + paused_reason·request null
5. **bash 상호운용**: queue.sh(`QUEUE_LIB=1`)로 add/claim한 파일을 python ops가 읽고 조작, 그 결과를 queue.sh가 다시 읽음 — 같은 락 디렉터리 사용 확인
6. request: running에 pause 기록 → queue_checkpoint가 exit 4 (기존 계약과 접점 검증)

## 범위 밖

- 원격(폰) 접근 — 원격 결정 브리지 통합은 후속
- 워커 시작/중지 버튼(프로세스 제어) — UI는 파일 계약만 만지고, `queue.sh work` 실행은 터미널 소유
- 인증·HTTPS — localhost 전용
