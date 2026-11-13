#!/usr/bin/env python3
"""올림푸스 알림 발송(Gmail SMTP). best-effort. 비밀은 env에서."""
import argparse, html, os, ssl, smtplib, sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

def _html_body(body, link):
    """본문 + 깃 문서로 가는 버튼을 담은 HTML 파트."""
    safe = html.escape(body).replace("\n", "<br>")
    button = (
        f'<p style="margin:24px 0"><a href="{html.escape(link, quote=True)}" '
        'style="background:#238636;color:#fff;text-decoration:none;'
        'padding:12px 20px;border-radius:8px;font-weight:600;display:inline-block">'
        '📝 GitHub에서 답변하기</a></p>'
        f'<p style="color:#57606a;font-size:12px">링크: '
        f'<a href="{html.escape(link, quote=True)}">{html.escape(link)}</a></p>'
    )
    return (
        '<div style="font-family:-apple-system,Segoe UI,sans-serif;'
        'font-size:14px;line-height:1.6;color:#1f2328">'
        f'<div>{safe}</div>{button}</div>'
    )

def build(sender, to, subject, body, link=None):
    m = EmailMessage()
    m["Subject"] = subject
    m["From"] = f"Olympus 원격결정 <{sender}>"
    m["To"] = to
    m["Date"] = formatdate(localtime=True)
    m["Message-ID"] = make_msgid(domain="gmail.com")
    m["Importance"] = "high"; m["X-Priority"] = "1"
    # 플레인 텍스트(폴백)에도 링크 URL을 명시 — HTML 미지원 클라이언트 대비.
    plain = body if not link else f"{body}\n\n답변하기: {link}"
    m.set_content(plain)
    if link:
        m.add_alternative(_html_body(body, link), subtype="html")
    return m

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--subject", required=True)
    ap.add_argument("--body-file", required=True)
    ap.add_argument("--link", default="")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    sender = os.environ.get("SMTP_SENDER", "")
    pw = os.environ.get("SMTP_APP_PASSWORD", "").replace(" ", "")
    to = os.environ.get("NOTIFY_EMAIL", sender)
    with open(a.body_file, encoding="utf-8") as f:
        body = f.read()
    if not sender or not pw:
        print("SMTP 비밀 없음(.env.local 미설정) — 알림 스킵", file=sys.stderr)
        sys.exit(1)
    link = a.link or None
    msg = build(sender, to, a.subject, body, link)
    if a.dry_run:
        # as_string()/as_bytes()는 비ASCII 헤더·본문을 RFC2047/base64로 인코딩해
        # 사람이 읽을 수 없다(실제 발송은 그 인코딩이 맞음). dry-run은 디코딩된
        # 값으로 사람이 읽을 메시지를 재구성해 출력한다(발송 경로는 손대지 않음).
        headers = ("Subject", "From", "To", "Date", "Message-ID", "Importance", "X-Priority")
        for h in headers:
            print(f"{h}: {msg[h]}")
        print()
        # multipart(링크 있을 때)/singlepart 모두에서 plain 파트를 안전하게 꺼낸다.
        plain_part = msg.get_body(preferencelist=("plain",))
        print(plain_part.get_content().rstrip("\n"))
        if link:
            print(f"[HTML BUTTON] 📝 GitHub에서 답변하기 → {link}")
        return
    host = os.environ.get("SMTP_HOST", "smtp.gmail.com")
    port = int(os.environ.get("SMTP_PORT", "587"))
    ctx = ssl.create_default_context()
    try:
        with smtplib.SMTP(host, port) as s:
            s.starttls(context=ctx); s.login(sender, pw); s.send_message(msg)
    except Exception as e:
        # 비밀번호는 절대 출력하지 않는다. 예외 타입명만 로그로 남긴다.
        print(f"SMTP 발송 실패({type(e).__name__}) — 알림 실패", file=sys.stderr)
        sys.exit(2)
    print(f"SENT → {to}")

if __name__ == "__main__":
    main()
