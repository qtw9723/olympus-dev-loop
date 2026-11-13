# 올림푸스 최종 승인 — Gmail 답장 경로 (설계)

- 작성일: 2026-07-03
- 브랜치: `feat/email-reply-approval`
- 목적: **잦은** 최종 머지 승인(yes/no 하나)을, GitHub 파일 편집보다 **가벼운 경로**로 전환.
  블로커·의도 질문은 지금처럼 GitHub `pending/<id>.md`(자유서술 필요) 그대로 둔다.

## 배경 — 왜 최종 승인만 분리하나

- 사람 개입 3지점 중 **블로커·의도질문**은 자유서술이 필요해 GitHub 파일 편집이 정당하다.
- **최종 머지 승인**은 사실상 `y`/`n` 하나인데, 지금은 같은 GitHub 경로(파일 열기→`## 답변` 편집→commit)라 무겁다. 게다가 잘 쓴 기획서에선 이 승인이 **가장 자주** 발동한다(블로커/의도질문은 드묾).
- 새 서비스는 늘리지 않는다 → 이미 발송에 쓰는 **Gmail 계정을 답장 수신(IMAP)에도 재사용**한다(사용자 결정).

## 동작 (한 줄)

승인 요청 메일에 **답장으로 첫 줄에 `y`(보류 `n`)만 적어 보내면**, run.sh가 같은 프로세스에서 Gmail IMAP을 폴링해 감지하고 그대로 이어간다. `remote_ask`와 **동일한 계약**(stdout=답, rc 0/3)이라 run.sh 통합은 드롭인.

## 견고화 설계 (fragile 지점 잠금)

1. **run 매칭 = subject 토큰**
   - 요청 메일 제목에 유일 토큰을 박음: `[올림푸스] 최종 머지 승인 ‹OLY-<id>›` (`<id>`=`date +%Y%m%d-%H%M%S`).
   - 답장은 `Re: …‹OLY-<id>›`로 토큰을 보존 → IMAP은 **subject에 토큰 포함**된 UNSEEN 메일만 스캔. (In-Reply-To 있으면 보조 확인.)

2. **인용문 오탐 차단 = 최상단 비인용 한 줄만 파싱**
   - 본문에서 **인용부 이전의 첫 비어있지 않은 줄**만 읽는다.
   - 인용부 마커: `>`로 시작 / `On … wrote:` / `…님이 작성:` / `-----Original Message-----` / `________` (Outlook) / `보낸 사람:`·`From:` 블록.
   - 그 한 줄을 **whole-line·대소문자 무시·trim** 매칭. 원문 인용에 키워드가 섞여도 인용부라 안 걸린다.
   - 요청 메일 본문 **첫 줄은 키워드가 아닌 안내문** → 자기수신 사본이 스캔돼도 매칭 안 됨(추가 안전망).

3. **위조 차단 = From 화이트리스트**
   - 답장의 From 주소가 `APPROVE_FROM`(기본 `SMTP_SENDER`)을 포함할 때만 인정. 남이 inbox에 메일 쏴서 머지 트리거 방지.

4. **재처리 방지 + 폴백**
   - 답으로 소비한 메일만 `\Seen` 마킹. 매칭 안 된 메일은 건드리지 않음(자기수신 원문은 무해히 재스캔).
   - `POLL_TIMEOUT_SEC` 초과 → rc 3 → run.sh가 **기존 폴백(보류/수동 머지)** 그대로.
   - IMAP 비밀 없음/접속 실패 → rc 4 → run.sh가 **GitHub `remote_ask` 경로로 폴백**(무손상).

5. **키워드 세트**
   - 승인(y): `y` `yes` `승인` `approve` `ok`
   - 보류(n): `n` `no` `보류` `거부` `reject`
   - 매칭 결과를 `y`/`n`으로 **정규화**해 반환 → run.sh의 `[ "$a" = "y" ]` 무변경.

## 컴포넌트

### 1. `inbox_imap.py` (신설)
- `--await --token OLY-… --from <addr> --timeout N --poll N` : IMAP 폴링 루프. 감지 시 `y`/`n`을 stdout에 출력하고 exit 0. 타임아웃 exit 3. 비밀없음 exit 4. 접속실패 exit 5.
- `--parse <file>` : (테스트용, notify.py `--dry-run`과 같은 급) 답장 본문 파일을 받아 파싱 결과(`y`/`n`/빈줄)를 출력. **fragile 로직을 네트워크 없이 검증**.
- IMAP 비밀 재사용: `IMAP_USER=SMTP_SENDER`, `IMAP_PASS=SMTP_APP_PASSWORD`, `IMAP_HOST`(기본 imap.gmail.com), `IMAP_PORT`(993).

### 2. `remote.sh`에 `remote_approve_email <id> <bodyfile>` 추가
- 토큰 생성 → notify.py로 **안내문+승인질문**을 발송(링크 버튼 없음, 답장 안내) → `inbox_imap.py --await` 호출 → 결과/코드 그대로 전파.
- notify.py 발송 실패는 best-effort(폴링은 계속). IMAP 비밀 없음/실패(rc 4/5)면 호출부가 remote_ask로 폴백.

### 3. `run.sh` 최종 승인 블록(288–296) 배선
```bash
if remote_enabled; then
  if [ "${APPROVE_VIA_EMAIL:-1}" = "1" ]; then
    a="$(remote_approve_email "$(date +%Y%m%d-%H%M%S)" "$APPROVE_Q")"; rc=$?
    if [ "$rc" -eq 4 ] || [ "$rc" -eq 5 ]; then          # IMAP 불가 → GitHub 폴백
      a="$(remote_ask "$(date …)" approval "최종 머지 승인" "$APPROVE_Q")"; rc=$?
    fi
  else
    a="$(remote_ask … approval …)"; rc=$?
  fi
  [ "$rc" -ne 0 ] && { echo "⏱️ 승인 응답 타임아웃/불가 — 보류(수동 머지)."; exit 0; }
fi
```

### 4. `config.sh` 노브
- `APPROVE_VIA_EMAIL`(기본 1) — 최종 승인을 Gmail 답장으로. 0이면 기존 GitHub 경로.
- `APPROVE_FROM`(기본 `$SMTP_SENDER`) — 답장 허용 발신자.
- IMAP 호스트/포트는 python 기본값(env override 가능).

## 범위 밖 (변경 없음)
- 블로커/의도질문 → GitHub `remote_ask` 유지.
- notify.py 발송 로직/계약(exit 1/2) 유지(안내문 발송에 그대로 사용).
- 토큰 대기·배포·아카이브 단계 무변경.

## 테스트 전략
- **파싱(핵심 fragile)**: `inbox_imap.py --parse`로 다양한 답장 본문(상단답+인용, 인용 속 키워드, top-post 빈줄, HTML-only, 대소문자, 한/영 키워드, 무매칭)을 pure-bash 어설션으로 검증.
- **폴백/정규화**: `remote_approve_email`의 rc 전파와 `y`/`n` 정규화.
- IMAP 접속 루프 자체는 실서버 필요 → **수동 E2E**(이전 브리지와 동일 방식)로 최종 확인.
