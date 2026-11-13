#!/usr/bin/env python3
# server.py — 큐 웹 UI 로컬 서버 (표준라이브러리만, 127.0.0.1 전용).
# 실행: bash ui.sh [포트]  또는  python3 ui/server.py [--port 8765]
# 쓰기는 전부 queue_ops의 시맨틱 조작으로만 — 워커 소유 필드는 여기서 변경 불가.
import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import queue_ops as ops

INDEX_HTML = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
USAGE_HTML = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage.html")

# POST 본문 필드 → queue_ops 호출 매핑
ACTIONS = {
    "/api/add":     lambda b: ops.add(b["project"], b.get("mode", "auto")),
    "/api/remove":  lambda b: ops.remove(b["id"]),
    "/api/reorder": lambda b: ops.reorder(b["order"]),
    "/api/mode":    lambda b: ops.set_mode(b["id"], b["mode"]),
    "/api/resume":  lambda b: ops.resume(b["id"]),
    "/api/request": lambda b: ops.request(b["id"], b["action"]),
    "/api/answer":  lambda b: ops.answer(b["id"], b["answer"]),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # 조용히 (조작 오류는 응답으로 전달됨)
        pass

    def _json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self._json(500, {"error": os.path.basename(path) + " 없음"})
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/", "/index.html"):
            self._send_file(INDEX_HTML, "text/html; charset=utf-8")
        elif url.path == "/usage":
            self._send_file(USAGE_HTML, "text/html; charset=utf-8")
        elif url.path == "/api/queue":
            self._json(200, ops.snapshot())
        elif url.path == "/api/decisions":
            self._json(200, ops.decisions())
        elif url.path == "/api/usage":
            self._json(200, ops.usage())
        elif url.path == "/api/usage/breakdown":
            self._json(200, ops.usage_breakdown())
        elif url.path == "/api/detail":
            project = parse_qs(url.query).get("project", [""])[0]
            try:
                self._json(200, ops.detail(project))
            except ops.OpError as e:
                self._json(e.status, {"error": str(e)})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        action = ACTIONS.get(urlparse(self.path).path)
        if not action:
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            result = action(body)
            self._json(200, {"ok": True, "result": result})
        except ops.OpError as e:
            self._json(e.status, {"error": str(e)})
        except (KeyError, ValueError, TypeError) as e:
            self._json(400, {"error": f"잘못된 요청: {e}"})


def main():
    ap = argparse.ArgumentParser(description="올림푸스 큐 웹 UI")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"🌐 올림푸스 큐 UI — http://127.0.0.1:{args.port} (중지: Ctrl+C)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
