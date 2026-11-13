#!/usr/bin/env python3
"""올림푸스 최종 승인 — Gmail 답장 수신(IMAP 폴링). 비밀은 SMTP와 공유(env).

계약(run.sh/remote.sh와):
  --await --token OLY-… --from <addr> [--timeout N] [--poll N]
      감지 시 stdout에 y|n, exit 0 / 타임아웃 exit 3 / 비밀없음 exit 4 / 접속실패 exit 5
  --parse <file>
      답장 본문 파일 → y|n|빈줄 (fragile 파싱을 네트워크 없이 검증)
"""
import argparse, html, imaplib, os, re, sys, time
from email import message_from_bytes
from email.header import decode_header, make_header
from email.utils import parseaddr

_YES = {"y", "yes", "승인", "approve", "ok"}
_NO = {"n", "no", "보류", "거부", "reject"}


def _is_quote(s):
    """이 줄이 인용부/구분선 시작이면 True (여기서부터는 원문이라 답으로 안 읽음)."""
    if s.startswith(">"):
        return True
    if re.match(r"^-{3,}\s*Original Message\s*-{3,}", s, re.I):
        return True
    if re.match(r"^_{5,}\s*$", s):                      # Outlook 구분선
        return True
    if re.search(r"wrote:\s*$", s):                     # "On … wrote:"
        return True
    if re.search(r"님이\s*작성", s):                     # 한글 Gmail "… 님이 작성:"
        return True
    if re.match(r"^(보낸\s*사람|From)\s*:", s):          # 헤더 블록 시작
        return True
    return False


def _strip_html(text):
    """HTML-only 본문 대비: 블록태그→개행, 나머지 태그 제거, 엔티티 복원."""
    t = re.sub(r"(?i)<\s*(br|/div|/p|/blockquote|div|p|blockquote)[^>]*>", "\n", text)
    t = re.sub(r"<[^>]+>", "", t)
    return html.unescape(t)


def _first_reply_line(body):
    """인용부 이전의 첫 비어있지 않은 줄(trim). 없으면 None."""
    if re.search(r"<[a-zA-Z/][^>]*>", body):            # HTML로 보이면 태그 제거
        body = _strip_html(body)
    for raw in body.splitlines():
        s = raw.strip()
        if not s:
            continue
        if _is_quote(s):
            return None
        return s
    return None


def _classify(body):
    """본문 → 'y' | 'n' | '' (whole-line·대소문자 무시)."""
    line = _first_reply_line(body)
    if line is None:
        return ""
    t = line.strip().lower()
    if t in _YES:
        return "y"
    if t in _NO:
        return "n"
    return ""


def _body_text(msg):
    """메시지에서 사람이 쓴 본문 추출: text/plain 우선, 없으면 html strip."""
    plain, htmlp = None, None
    if msg.is_multipart():
        for part in msg.walk():
            ctype = part.get_content_type()
            if part.get_content_disposition() == "attachment":
                continue
            if ctype == "text/plain" and plain is None:
                plain = part
            elif ctype == "text/html" and htmlp is None:
                htmlp = part
    else:
        if msg.get_content_type() == "text/html":
            htmlp = msg
        else:
            plain = msg
    part = plain or htmlp
    if part is None:
        return ""
    try:
        payload = part.get_payload(decode=True)
        charset = part.get_content_charset() or "utf-8"
        return payload.decode(charset, "replace") if payload else ""
    except Exception:
        return ""


def _connect():
    user = os.environ.get("IMAP_USER") or os.environ.get("SMTP_SENDER", "")
    pw = (os.environ.get("IMAP_PASS") or os.environ.get("SMTP_APP_PASSWORD", "")).replace(" ", "")
    if not user or not pw:
        return None, 4
    host = os.environ.get("IMAP_HOST", "imap.gmail.com")
    port = int(os.environ.get("IMAP_PORT", "993"))
    try:
        m = imaplib.IMAP4_SSL(host, port)
        m.login(user, pw)
        return m, 0
    except Exception as e:
        print(f"IMAP 접속 실패({type(e).__name__})", file=sys.stderr)
        return None, 5


def _uidnext(m):
    """INBOX의 UIDNEXT(다음에 부여될 UID). 대기 시작 이후 새 메일만 보기 위한 기준선."""
    try:
        typ, d = m.status("INBOX", "(UIDNEXT)")
        if typ == "OK" and d and d[0]:
            mm = re.search(rb"UIDNEXT (\d+)", d[0])
            if mm:
                return int(mm.group(1))
    except Exception:
        pass
    return 0


def await_reply(token, from_allow, timeout, poll):
    m, rc = _connect()
    if m is None:
        return rc
    from_allow = (from_allow or "").lower()
    m.select("INBOX")
    baseline = _uidnext(m)                              # 이 시점 이후 도착분만 처리
    waited = 0
    try:
        while True:
            try:
                m.select("INBOX")
                # FROM은 서버 검색이 신뢰성 높음(위조 차단 1차). 제목 토큰은
                # RFC2047 인코딩되면 SUBJECT 검색이 서버별로 불안정 → 파이썬에서
                # 디코드해 확인한다.
                crit = ("UNSEEN", "FROM", from_allow) if from_allow else ("UNSEEN",)
                typ, data = m.uid("SEARCH", None, *crit)
                uids = data[0].split() if (typ == "OK" and data and data[0]) else []
                for uid in reversed(uids):              # 최신부터
                    try:
                        if baseline and int(uid) < baseline:
                            continue                    # 대기 시작 전 옛 메일 스킵
                    except ValueError:
                        pass
                    t2, d2 = m.uid("FETCH", uid, "(RFC822)")
                    if t2 != "OK" or not d2 or not d2[0]:
                        continue
                    msg = message_from_bytes(d2[0][1])
                    sender = parseaddr(msg.get("From", ""))[1].lower()
                    if from_allow and from_allow not in sender:
                        continue                        # 위조 차단: 허용 발신자만
                    subject = str(make_header(decode_header(msg.get("Subject", ""))))
                    if token not in subject:            # run 매칭: 디코드된 제목 토큰
                        continue
                    verdict = _classify(_body_text(msg))
                    if verdict:
                        m.uid("STORE", uid, "+FLAGS", "(\\Seen)")
                        print(verdict)
                        return 0
            except Exception as e:                      # 일시 오류 → 재접속 시도
                print(f"IMAP 폴링 오류({type(e).__name__}) — 재접속", file=sys.stderr)
                try:
                    m.logout()
                except Exception:
                    pass
                m, rc = _connect()
                if m is None:
                    return rc
            if waited >= timeout:
                return 3
            time.sleep(poll)
            waited += poll
    finally:
        try:
            m.logout()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--await", dest="await_", action="store_true")
    ap.add_argument("--parse")
    ap.add_argument("--token", default="")
    ap.add_argument("--from", dest="from_allow", default="")
    ap.add_argument("--timeout", type=int, default=21600)
    ap.add_argument("--poll", type=int, default=30)
    a = ap.parse_args()

    if a.parse:
        with open(a.parse, encoding="utf-8") as f:
            print(_classify(f.read()))
        return
    if a.await_:
        if not a.token:
            print("--token 필요", file=sys.stderr)
            sys.exit(2)
        sys.exit(await_reply(a.token, a.from_allow, a.timeout, a.poll))
    ap.error("--await 또는 --parse 필요")


if __name__ == "__main__":
    main()
