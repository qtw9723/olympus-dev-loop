# 큐 UI 사용량 대시보드 — 설계

- 날짜: 2026-07-14
- 브랜치: `feat/usage-dashboard`
- 상태: 승인됨(설계), 구현 대기

## 배경 / 목적

큐 웹 UI 헤더에 전 프로젝트 누적 토큰 합계(`🎟 전체 N tok · ~$X`)가 이미 표시된다(커밋 `b93cb09`).
사용자는 이 합계를 **프로젝트별·일자별**로 분해해 확인하기를 원한다.

필요한 데이터는 이미 존재한다: `run.sh`가 턴마다 `state/<project>/usage.tsv`에 다음 컬럼으로 append 한다.

```
ts  run  round  role  model  input  output  cache_read  cache_create
```

- 프로젝트 = 폴더명(`state/<project>/`)
- 날짜 = `ts` 컬럼 앞 10자(`YYYY-MM-DD`)

즉 데이터 파이프라인 변경은 없고, **집계와 표시만 확장**한다.

## 데이터 소스 정합성 (중요)

두 개의 서로 다른 토큰 소스가 있다:

| 소스 | 읽는 곳 | 의미 |
|---|---|---|
| `state/*/usage.tsv` | 큐 UI 헤더(`queue_ops.usage()`) | 올림푸스 파이프라인이 각 프로젝트 작업하며 쓴 토큰 |
| `~/.claude/projects/*.jsonl` | `usage-report.sh --html` | 올림푸스 무관 포함, 모든 Claude Code 세션 |

본 대시보드는 사용자가 칭찬한 **헤더 총계를 분해**하는 것이 목적이므로 **반드시 `state/*/usage.tsv`를 소스로 사용**한다. jsonl을 쓰면 헤더보다 큰(무관한 사용 포함) 숫자가 나와 혼란을 준다. 대시보드 상단 요약 카드의 총계는 기존 `usage()` 총계와 **정확히 일치**해야 한다.

## 아키텍처

실행 중인 로컬 UI 서버(`ui/server.py`, 표준 라이브러리만, 127.0.0.1 전용)에 세 가지를 추가한다. 기존 헤더용 `usage()`와 `/api/usage`는 그대로 유지한다(비침습).

### 1. 집계 함수 `queue_ops.usage_breakdown()`

`state/*/usage.tsv`를 순회하며 프로젝트별·일자별·프로젝트×일자로 합산. 단가/비용 환산은 기존 `_price()`를 재사용(로직 중복 금지). 파싱 실패 행·헤더 행은 기존 `usage()`와 동일하게 스킵.

반환 형태:

```python
{
  "total":    {"total": int, "cost": float, "calls": int},
  "projects": [  # 비용 내림차순 정렬
    {"name": str, "total": int, "cost": float, "calls": int,
     "first": "YYYY-MM-DD", "last": "YYYY-MM-DD"},
    ...
  ],
  "days": [  # 날짜 오름차순
    {"day": "YYYY-MM-DD", "total": int, "cost": float, "calls": int},
    ...
  ],
  "cells": {  # 프로젝트×일자 매트릭스, 값이 0인 셀은 생략
    "<project>|<day>": {"total": int, "cost": float},
    ...
  }
}
```

- `total.total` = Σ(input+output+cache_read+cache_create) — `usage()["total"]`과 동일해야 함
- `cost` 환산식은 기존과 동일: `(i*pin + cr*pin*0.1 + cc*pin*1.25 + o*pout) / 1e6`

### 2. API 엔드포인트 `/api/usage/breakdown`

`ui/server.py`의 `do_GET`에 라우트 추가 → `ops.usage_breakdown()` JSON 반환. 기존 `/api/usage` 옆에 나란히.

### 3. 대시보드 페이지 `/usage` (`ui/usage.html`)

`do_GET`에서 `/usage` 요청 시 `ui/usage.html`을 `text/html`로 서빙(index.html 서빙과 동일 패턴). 페이지는 로드 시 `/api/usage/breakdown`을 fetch해 클라이언트에서 렌더한다. 서버 렌더링 없음.

디자인 언어는 기존 `usage-report.sh --html` 대시보드와 동일하게 맞춘다(다크 `#0f1417`, 오렌지 액센트 `#e8a13a`, 카드/표/막대, ui-monospace 숫자). 시각 일관성 목적.

**대시보드 구성:**

1. **요약 카드** — 총 토큰 / 환산$ / 프로젝트 수 / 총 호출 (헤더 총계와 일치)
2. **프로젝트별 표** — 토큰·환산$·호출·기간 + 비용 비례 막대, 비용 내림차순
3. **일자별 표** — 날짜순, 토큰·환산$ + 막대
4. **프로젝트×일자 매트릭스** — 행=프로젝트, 열=날짜, 셀=토큰(값 클수록 색농도↑), 우측/하단 합계. 가로 스크롤 허용(`overflow-x:auto`).

### 4. 헤더 진입점

`ui/index.html` 헤더의 `🎟` 위젯 옆에 `📊 사용량 상세` 링크/버튼 추가 → `/usage`를 새 탭(`target="_blank"`)으로 연다.

## 에러 처리

- TSV가 하나도 없거나 전부 비면: 대시보드는 "기록 없음" 빈 상태 안내를 표시.
- 파싱 실패 행(컬럼 부족, 숫자 아님): 스킵(기존 `usage()` 방어와 동일).
- `/api/usage/breakdown` 실패 시: 페이지는 토스트/문구로 "서버 연결 실패" 안내(기존 `api()` 패턴 참고).

## 테스트

`queue_ops.py usage_breakdown` CLI 서브커맨드를 추가하고(기존 `_cli` 패턴), `test/`의 기존 셸 테스트 패턴을 따라 검증한다:

1. **정합성 회귀**: `usage_breakdown()["total"]["total"]` == `usage()["total"]` (두 집계 소스가 일치).
2. **분해 합산**: Σ(projects[].total) == total.total, Σ(days[].total) == total.total.
3. **매트릭스 합산**: Σ(cells 값) == total.total.
4. **빈 상태**: 임시 빈 QUEUE_ROOT에서 빈 구조 반환(예외 없음).

## 범위 밖 (YAGNI)

- 모델별 분해 (컬럼은 있으나 이번엔 안 함)
- 기간 필터 UI (전체 기간만)
- jsonl 소스 병합
- 실시간 캡 잔량(`/usage`는 대화형 claude에서)

## 영향 파일

- `ui/queue_ops.py` — `usage_breakdown()` 추가, `_cli`에 서브커맨드 추가
- `ui/server.py` — `/api/usage/breakdown`, `/usage` 라우트 추가
- `ui/usage.html` — 신규
- `ui/index.html` — 헤더에 진입점 링크 추가
- `test/` — 신규 테스트 스크립트
