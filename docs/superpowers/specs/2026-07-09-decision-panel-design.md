# 올림푸스 웹 UI 결정 패널 — 설계

날짜: 2026-07-09
상태: 설계 확정
브랜치: feat/ui-decision-panel
선행 스펙: 2026-07-08-queue-web-ui-design.md (본 패널은 그 UI의 확장)

## 목적

큐 모드에서 블로커 질문은 항목을 paused(blocker)로 눕히고 넘어간다(설계 의도 — 큐 정체 방지).
현재 답변 경로는 `state/<프로젝트>/human-answers.md` 수동 편집뿐이다. 이 간극을 UI로 메운다:
**질문을 보고 → 답을 적고 → 자동 재개**. 재개 후 소비는 기존 계약(메티스 M0가 human-answers 최우선 반영)이 담당한다.

## 확정 결정

| 항목 | 결정 | 근거 |
|---|---|---|
| 범위 | 블로커 답변+자동 재개, open-questions 표시(읽기만) | "간단한 의사결정". 최종 머지 승인 y/n은 이메일 토큰 경로라 run.sh 변경 필요 → 후속 |
| 답변 파일 | `human-answers.md`에 **append만** (run.sh 원격 답 포맷 호환) | human-answers는 사람 소유 파일 — UI는 사람의 프록시. 워커 소유 파일(questions.md 등)은 불가침 유지 |
| 재개 | 답변과 동시에 paused→queued (기존 resume 전이 재사용) | 감시 모드가 곧 집어감. 답이 부족하면 메티스가 다시 블로커로 눕힘(자연 재질문 루프) |
| 원격 브리지와 관계 | 충돌 없음 — 큐 모드는 원격 폴링을 안 함(run.sh:100) | 폰=비큐 원격, UI=큐 로컬. 같은 human-answers.md 계약으로 수렴. 비큐 실행 답변은 범위 밖 |
| run.sh 변경 | 없음 | 재개→메티스 M0→human-answers 반영이 기존 계약으로 완결 |

## API 추가 (server.py + queue_ops.py)

| 메서드/경로 | 동작 | 가드 |
|---|---|---|
| GET `/api/decisions` | `blockers`: paused(blocker) 항목별 {id, project, question(=state/<p>/questions.md, 없으면 null)} + `open_questions`: state/<p>/open-questions.md가 있는 프로젝트별 {project, content} | 읽기 전용, 프로젝트명 화이트리스트 |
| POST `/api/answer` `{id, answer}` | ① 검증: 항목 존재·paused·paused_reason=blocker·answer 비공백 ② human-answers.md append ③ resume 전이(paused→queued, paused_reason·request null) | 검증 실패 409/400, 큐 변경은 기존 mkdir 락 경유 |

append 포맷(run.sh ask_human_or_stop과 호환):

```
## [blocker] UI 답변 (id=<YYYYMMDD-HHMMSS>)
**질문:**
<questions.md 내용 또는 "(questions.md 없음)">

**사람 답:**
<answer>
```

원자성: 검증 → append → 전이 순서를 큐 락 안에서 수행. append 후 저장 실패 시 답은 파일에 남고
항목은 paused 유지 — 사람이 재개 버튼만 다시 누르면 됨(멱등 방향으로 안전).

## 화면

1. 대기열 위에 **"🙋 결정 대기" 패널** — blocker 항목이 있을 때만 표시. 카드마다:
   프로젝트명 + 질문 전문(pre) + textarea + [답변하고 재개] 버튼.
2. 패널 하단 접이식 **"열린 질문(참고)"** — open-questions.md 내용 읽기 전용(가정으로 진행된 의문 확인용).
3. 기존 2초 폴링에 /api/decisions 동승(별도 타이머 없음 — refresh에서 함께 조회).

## 테스트 (test/ui_decisions_test.sh)

1. decisions: blocker 항목+questions.md → 목록에 질문 포함, open-questions.md → open_questions 포함
2. answer 정상: human-answers.md 포맷(질문·답 포함) + queued 전이 + paused_reason/request null
3. 가드: 미존재 id / queued 항목 / paused(human) 항목 / 빈 답 → 거부
4. bash 상호운용: queue.sh(QUEUE_LIB)로 add/claim→blocker 눕힘 → python ops answer → queue.sh가 queued로 읽음

## 범위 밖

- 최종 머지 승인 y/n(로컬 승인 파일 경로 신설 필요 — run.sh 변경 수반), 비큐+REMOTE 실행 답변
- 원격(폰) 결정 패널 — Phase2(Supabase)에서 본 데이터 모양을 미러링
