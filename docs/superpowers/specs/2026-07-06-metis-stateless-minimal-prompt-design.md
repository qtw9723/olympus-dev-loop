# 설계: 메티스 무상태 세션 + 최소 프롬프트 주입 + 진행 저널

날짜: 2026-07-06
상태: 승인됨

## 문제

- 메티스는 `--session-id`→`--resume`으로 세션을 유지하면서, **매 호출 spec 전체(~35KB) + 상태 파일 전부를 프롬프트에 인라인** 주입한다. 세션에 호출 횟수만큼 전체 문서 사본이 누적된다.
- 토큰 쿼터 소진 대기(수 시간) 후 재개하면 프롬프트 캐시(5분 TTL)가 완전히 식어, **누적된 세션 전체를 캐시 없이 입력 토큰으로 재독** — 새 쿼터를 시작하자마자 큰 비용을 선불로 낸다.
- `claude_guarded`는 한도 감지 시 호출 전체를 처음부터 재실행 — 중단 시점까지의 작업 맥락을 활용하지 못한다.

## 결정 (사용자 요구)

1. **매 태스크(호출)마다 새 세션** — 메티스도 worker처럼 무상태로.
2. **프롬프트는 해당 태스크에 필요한 만큼만** 전달.
3. **중단 후 재개 시 남은 작업에 필요한 만큼만** — durable 파일 메모리 활용.

## 설계

### 1. 메티스 무상태화 + 모드별 호출

- `run.sh`의 `metis()`에서 `--session-id`/`--resume`/`METIS_SID`/`METIS_STARTED` 제거. 매 호출 새 세션.
- 호출 지점이 이미 모드를 알고 있으므로 `metis <모드>`로 힌트를 전달한다:
  - Phase 0 → `metis M0` (요구사항 분석)
  - `resolve_intent` → `metis M1` (질문 응답)
  - 태스크 green 후 → `metis M2` (트리아지 + 다음 작업)
- 기억은 전적으로 durable 파일(`requirements.md`, `decisions.md`, `backlog.md`)에 의존한다. 이는 `roles/metis.md`가 이미 "매번 먼저 읽고 갱신"하도록 설계된 바와 일치한다.

### 2. 프롬프트 다이어트: 인라인 → 참조 기반

모든 세션은 `--add-dir "$PIPELINE_DIR"`로 파일 접근이 가능하므로, 대형 문서는 **경로 참조 + 직접 읽기 지시**로 전환한다.

- **spec 전체 인라인 폐지**. M0 프롬프트에 "spec 디렉토리 경로 + 그 안의 .md를 직접 읽어라"만 전달.
- 모드별 최소 인라인(소형 핫 파일만):
  - M0: (인라인 없음 — spec 경로 참조)
  - M1: `ask-planner.md` (질문 큐)
  - M2: `findings.md` + `backlog.md`
- worker(빌더/크리틱): `task.md` + `critic-feedback.md` + `progress.md`만 인라인. `requirements.md`는 "의도가 불명확하면 읽어라"로 참조 전환.
- 프롬프트 조립을 `prompts.sh`(소스 가능한 라이브러리)로 추출해 기존 패턴(resilience.sh 등)대로 bash 테스트를 붙인다.

### 3. 진행 저널 `state/progress.md`

- 빌더/크리틱 역할 문서에 추가: **의미 있는 단계를 마칠 때마다** `state/progress.md`에 한 줄 기록 (`- [builder] 완료: X / 다음: Y`).
- worker 프롬프트에 "progress.md를 먼저 읽고, 이미 완료된 것은 건너뛰고 남은 것부터 이어서" 지시.
- 메티스 M2가 다음 태스크를 `task.md`로 복사할 때 `progress.md`를 초기화한다.
- `reset.sh` 초기화 목록에 `progress` 추가.

### 4. resilience.sh 무변경

프롬프트가 참조 기반이 되면, 토큰 대기 후 같은 프롬프트로 재시도해도 새 세션이 **런타임에 최신 progress.md·코드 상태를 읽으므로** 남은 작업만 이어간다. 재시도용 프롬프트 재조립 로직이 불필요하다. 디스크의 코드 변경은 중단돼도 유실되지 않고, 미완성분은 verify + Critic 게이트가 잡는다.

## 트레이드오프

- 메티스의 세션 대화 뉘앙스는 사라짐 → `requirements.md`/`decisions.md`가 유일한 기억. 역할 문서에 "답변·결정은 반드시 파일에 반영" 원칙이 이미 있으므로 이를 유지·강조.
- on-demand 파일 읽기는 툴콜 비용이 들지만 필요할 때만 발생 — 항상-인라인 대비 순이익.
- 인라인 주입 호출당 ~10k+ 토큰 → ~2-3k 토큰 예상.

## 테스트 전략

`test/prompts_test.sh` (기존 helpers.sh 패턴):
- 메티스 프롬프트에 spec 본문이 인라인되지 않음 / spec 경로는 포함됨
- M1 프롬프트에 ask-planner 내용 포함, findings 미포함 (모드 분리)
- M2 프롬프트에 findings·backlog 포함, ask-planner 미포함
- worker 프롬프트에 task·critic-feedback·progress 포함, requirements 본문 미인라인
- run.sh에 `--resume`/`--session-id`/`METIS_SID` 잔재 없음
