# 마일스톤 진행도 알림 설계 (2026-07-07)

## 목적

무인 실행 중 사용자가 폰(Gmail)으로 **파이프라인이 어디까지 왔는지** 알 수 있게,
마일스톤 지점마다 진행도 알림 메일을 보낸다. 지금은 개입 요청(질문/승인/토큰대기)만
메일이 오고, 순수 진행 상황은 로컬 로그를 봐야만 알 수 있다.

## 범위

- **채널**: 기존 `notify.py`(Gmail SMTP, best-effort) 재사용. 수신자는 기존 `NOTIFY_EMAIL` 그대로.
- **마일스톤 3지점** (run.sh 훅):
  1. **Phase 0 완료** — 요구사항 분석·백로그 분해 직후. "작업 N개로 분해" + todo 목록 요약.
  2. **각 작업 green+커밋 직후** — `commit_task` 다음, `metis M2` 이전. "진행 n/N — [작업명] 완료" + 남은 작업 목록. ← 핵심
  3. **전체 백로그 완료** — 최종 verify 직후. "전체 완료 — verify green/실패".
     (이후 머지 승인 요청은 기존 remote/IMAP 경로가 커버하므로 중복 발송하지 않는다.)
- **비범위**: 라운드 단위(Builder/Critic 왕복) 알림 — 너무 잦아 소음. 알림 채널 추가(푸시 등) 없음.

## 아키텍처 (A안: 모듈 신설)

`resilience.sh`와 같은 패턴의 소스형 모듈 **`milestones.sh`** 를 신설하고
run.sh가 다른 모듈들처럼 `[ -f ... ] && . milestones.sh` 로 로드한다.

### milestones.sh 함수

- `backlog_progress()` — `state/backlog.md`를 파싱해 `done total` 두 숫자를 출력.
  섹션 헤더(`## todo` / `## doing` / `## done`) 아래의 `^###` 작업 헤더 수를 센다.
  `(없음)` 플레이스홀더는 무시. 파일 없음/형식 이상이면 `0 0` (best-effort).
- `backlog_titles <section>` — 해당 섹션의 작업 제목(`###` 줄) 목록 출력. 본문 조립용.
- `milestone_notify <subject> <bodyfile>` — 발송 래퍼:
  - 로그 1줄은 항상 출력 (`🔔 [milestone] <subject>`).
  - `NOTIFY_MILESTONES=1`이고 `SMTP_APP_PASSWORD` 있으면 `notify.py` 호출, 실패는 무시(`|| true`).
  - **어떤 경우에도 비0을 반환하지 않는다** — 파이프라인을 절대 멈추지 않는 계약.

### run.sh 훅 3곳

1. Phase 0 성공 직후(needs_clarification 해소 뒤):
   제목 `[올림푸스] 분석 완료 — 작업 N개 (<프로젝트>)`,
   본문 = todo 목록.
2. 작업 루프에서 `commit_task` 직후:
   제목 `[올림푸스] 진행 n/N — <작업명> 완료 (<프로젝트>)`,
   본문 = 완료 작업명 + 남은 todo 목록(비면 "남은 작업 없음").
   작업명은 기존 run.sh와 같은 방식(`grep -m1 '##' state/task.md`)으로 추출.
   **주의**: backlog의 doing→done 이동은 이후 `metis M2`가 하므로, 이 시점의 진행도는
   `n = done + doing`으로 계산한다(이 지점에 도달한 doing 작업은 green이 보장됨).
3. 전체 완료의 최종 verify 직후:
   제목 `[올림푸스] 전체 완료 — verify green|실패 (<프로젝트>)`,
   본문 = 완료 작업 수 + diff --stat 요약.

훅은 모두 `command -v milestone_notify` 가드로 감싸 모듈 부재 시에도 run.sh가 동작한다
(기존 `run_deploy_phase`의 `command -v deploy_project` 패턴과 동일).

### config.sh

- `NOTIFY_MILESTONES="${NOTIFY_MILESTONES:-1}"` — 1=발송(기본), 0=끄기(로그 1줄만).

## 에러 처리

- SMTP 비밀 없음 → notify.py가 exit 1로 스킵, milestone_notify는 0 반환(기존 계약 재사용).
- 발송 실패(exit 2) → `|| true`로 무시. 진행 알림은 유실돼도 파이프라인 무손상이 우선.
- backlog.md 파싱 실패 → `0 0` 출력, 제목의 n/N만 어색해질 뿐 발송은 계속.

## 테스트 (test/milestones_test.sh, 기존 helpers.sh 스타일)

- `backlog_progress`: 픽스처 backlog.md(todo 2·doing 1·done 3)에서 `3 6` 반환.
- `(없음)` 플레이스홀더만 있는 섹션은 0으로 계산.
- 파일 없으면 `0 0`, 비0 종료 아님.
- `milestone_notify`: SMTP 비밀 없을 때 0 반환 + 로그 1줄 출력.
- `NOTIFY_MILESTONES=0`이면 notify.py 미호출(로그만).
- notify.py 호출 경로는 dry-run 아닌 **스텁**(PATH 앞에 가짜 python3 대신, `NOTIFY_PY` 변수로
  호출 대상 오버라이드 가능하게 해 호출 인자 기록)으로 검증.
- `test/run_tests.sh`는 `*_test.sh` 글롭 기반이라 새 파일이 자동 포함된다(러너 무수정).

## 마이그레이션/호환

- 기존 동작 변화 없음: 훅은 추가일 뿐, 기존 알림(토큰대기/원격질문/승인)과 독립.
- `NOTIFY_MILESTONES=0`으로 완전 이전 동작 복원 가능.
