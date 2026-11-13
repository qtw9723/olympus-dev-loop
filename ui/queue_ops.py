#!/usr/bin/env python3
# queue_ops.py — 웹 UI의 큐 조작 계층. state/queue.json 계약 v1의 UI 소유 필드만 만진다.
#   UI 소유: queued/paused 항목의 추가·삭제·배열 순서·mode, paused→queued 재개,
#            running 항목의 request("pause"|"cancel")만.
#   워커 소유(불가침): status/progress/mode_resolved/result/paused_reason/타임스탬프/worker.
# 락: queue.sh와 동일한 mkdir 락(state/queue.lock/ + pid, 스테일 pid 회수) + tmp→mv 원자적 쓰기.
# CLI(테스트·수동 조작용): python3 queue_ops.py <add|remove|reorder|mode|resume|request|snapshot|detail> ...
import datetime
import glob
import json
import os
import random
import re
import shutil
import sys
import tempfile
import time

PIPELINE_DIR = os.environ.get("PIPELINE_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUEUE_ROOT = os.path.join(PIPELINE_DIR, "state")
QUEUE_FILE = os.path.join(QUEUE_ROOT, "queue.json")
QUEUE_LOCK = os.path.join(QUEUE_ROOT, "queue.lock")
LOCK_MAX_TRIES = int(os.environ.get("QUEUE_LOCK_MAX_TRIES", "100"))  # 0.1s 간격 → 기본 최대 10초
STALE_HEARTBEAT_SEC = 30 * 60
VALID_MODES = ("auto", "lite", "full")
PROJECT_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class OpError(Exception):
    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


def _now():
    return datetime.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ProcessLookupError, ValueError, TypeError):
        return False
    except PermissionError:
        return True


def _lock():
    os.makedirs(QUEUE_ROOT, exist_ok=True)
    for _ in range(LOCK_MAX_TRIES):
        try:
            os.mkdir(QUEUE_LOCK)
            with open(os.path.join(QUEUE_LOCK, "pid"), "w") as f:
                f.write(str(os.getpid()))
            return
        except FileExistsError:
            try:
                with open(os.path.join(QUEUE_LOCK, "pid")) as f:
                    holder = f.read().strip()
            except OSError:
                holder = ""
            if holder and not _pid_alive(holder):
                shutil.rmtree(QUEUE_LOCK, ignore_errors=True)
                continue
            time.sleep(0.1)
    raise OpError("큐 락 획득 실패 — 잠시 후 다시 시도하세요", status=503)


def _unlock():
    shutil.rmtree(QUEUE_LOCK, ignore_errors=True)


def _load():
    try:
        with open(QUEUE_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"version": 1, "worker": None, "items": []}


def _save(data):
    fd, tmp = tempfile.mkstemp(dir=QUEUE_ROOT, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
            f.write("\n")
        os.replace(tmp, QUEUE_FILE)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _edit(mutator):
    """락 → 읽기 → mutator(data) → tmp→mv. mutator가 OpError를 던지면 미변경."""
    _lock()
    try:
        data = _load()
        result = mutator(data)
        _save(data)
        return result
    finally:
        _unlock()


def _find(data, item_id):
    for it in data["items"]:
        if it.get("id") == item_id:
            return it
    raise OpError(f"항목 없음: {item_id}", status=404)


def _check_project_name(project):
    if not PROJECT_RE.match(project or ""):
        raise OpError("프로젝트명은 영숫자·점·하이픈·언더스코어만 허용")


def _guard_legacy():
    if os.path.isfile(os.path.join(QUEUE_ROOT, "handoff.json")):
        raise OpError("구 state 레이아웃 감지 — 먼저 실행: bash queue.sh migrate <프로젝트명>")


# ── UI 소유 조작 ──

def add(project, mode="auto"):
    _check_project_name(project)
    if mode not in VALID_MODES:
        raise OpError("mode는 auto|lite|full")
    if not os.path.isdir(os.path.join(PIPELINE_DIR, "spec", project)):
        raise OpError(f"spec/{project}/ 없음 — 기획서를 먼저 넣으세요")
    _guard_legacy()
    item = {
        "id": f"q-{time.strftime('%Y%m%d-%H%M%S')}-{random.randint(0, 32767)}",
        "project": project, "mode": mode, "mode_resolved": None,
        "status": "queued", "request": None, "progress": None,
        "enqueued_at": _now(), "started_at": None, "finished_at": None,
        "result": None, "paused_reason": None,
    }
    _edit(lambda data: data["items"].append(item))
    return item


def remove(item_id):
    def mut(data):
        it = _find(data, item_id)
        if it.get("status") == "running":
            raise OpError("실행 중 항목은 삭제 불가 — 취소 요청을 쓰세요")
        data["items"].remove(it)
    _edit(mut)


def reorder(order):
    def mut(data):
        current = [it.get("id") for it in data["items"]]
        if sorted(current) != sorted(order):
            raise OpError("순서 목록이 현재 큐와 불일치 — 새로고침 후 다시 시도하세요")
        by_id = {it.get("id"): it for it in data["items"]}
        data["items"] = [by_id[i] for i in order]
    _edit(mut)


def set_mode(item_id, mode):
    if mode not in VALID_MODES:
        raise OpError("mode는 auto|lite|full")
    def mut(data):
        it = _find(data, item_id)
        if it.get("status") not in ("queued", "paused"):
            raise OpError("mode 변경은 queued/paused 항목만 가능")
        it["mode"] = mode
    _edit(mut)


def resume(item_id):
    def mut(data):
        it = _find(data, item_id)
        if it.get("status") != "paused":
            raise OpError("재개는 paused 항목만 가능")
        it["status"] = "queued"
        it["paused_reason"] = None
        it["request"] = None
    _edit(mut)


def request(item_id, action):
    if action not in ("pause", "cancel"):
        raise OpError("request는 pause|cancel")
    def mut(data):
        it = _find(data, item_id)
        if it.get("status") != "running":
            raise OpError("pause/cancel 요청은 running 항목만 가능")
        it["request"] = action
    _edit(mut)


def answer(item_id, text):
    """블로커 답변: human-answers.md append(사람 소유 파일 — UI는 사람의 프록시) + 자동 재개.
    검증→append→전이를 큐 락 안에서 수행. append 후 저장이 실패해도 답은 파일에 남고
    항목은 paused 유지 — 재개 버튼만 다시 누르면 되는 방향으로 안전."""
    if not (text or "").strip():
        raise OpError("답변이 비어 있습니다", status=400)
    def mut(data):
        it = _find(data, item_id)
        if it.get("status") != "paused" or it.get("paused_reason") != "blocker":
            raise OpError("답변은 블로커로 멈춘(paused/blocker) 항목만 가능")
        project = it.get("project", "")
        _check_project_name(project)
        state_dir = os.path.join(QUEUE_ROOT, project)
        os.makedirs(state_dir, exist_ok=True)
        try:
            with open(os.path.join(state_dir, "questions.md")) as f:
                question = f.read().strip() or "(questions.md 없음)"
        except OSError:
            question = "(questions.md 없음)"
        block = (f"\n## [blocker] UI 답변 (id={time.strftime('%Y%m%d-%H%M%S')})\n"
                 f"**질문:**\n{question}\n\n**사람 답:**\n{text.strip()}\n")
        with open(os.path.join(state_dir, "human-answers.md"), "a") as f:
            f.write(block)
        it["status"] = "queued"
        it["paused_reason"] = None
        it["request"] = None
        return it
    return _edit(mut)


# ── 읽기 ──

def _worker_stale(worker):
    """표시용 파생값 — status 복구는 차기 워커 소유(계약)."""
    if not worker:
        return False
    if not _pid_alive(worker.get("pid")):
        return True
    try:
        hb = datetime.datetime.strptime(worker.get("heartbeat_at", ""), "%Y-%m-%dT%H:%M:%S%z")
        return (datetime.datetime.now(datetime.timezone.utc) - hb).total_seconds() > STALE_HEARTBEAT_SEC
    except ValueError:
        return False


def _spec_projects():
    root = os.path.join(PIPELINE_DIR, "spec")
    try:
        return sorted(d for d in os.listdir(root)
                      if os.path.isdir(os.path.join(root, d)) and PROJECT_RE.match(d))
    except FileNotFoundError:
        return []


def snapshot():
    data = _load()
    return {
        "version": data.get("version", 1),
        "worker": data.get("worker"),
        "items": data.get("items", []),
        "stale": _worker_stale(data.get("worker")),
        "projects": _spec_projects(),
    }


def _read_state_file(project, name):
    try:
        with open(os.path.join(QUEUE_ROOT, project, name)) as f:
            content = f.read().strip()
            return content or None
    except OSError:
        return None


def decisions():
    """대기 중인 결정 — blockers: paused(blocker) 항목별 질문, open_questions: 가정으로 진행된 의문(참고)."""
    data = _load()
    blockers = []
    for it in data.get("items", []):
        if it.get("status") == "paused" and it.get("paused_reason") == "blocker":
            project = it.get("project", "")
            if not PROJECT_RE.match(project):
                continue
            blockers.append({"id": it.get("id"), "project": project,
                             "question": _read_state_file(project, "questions.md")})
    open_questions = []
    try:
        state_projects = sorted(d for d in os.listdir(QUEUE_ROOT)
                                if os.path.isdir(os.path.join(QUEUE_ROOT, d)) and PROJECT_RE.match(d))
    except FileNotFoundError:
        state_projects = []
    for project in state_projects:
        content = _read_state_file(project, "open-questions.md")
        # 주석 플레이스홀더(<!-- ... -->)만 있는 파일은 "내용 없음"으로 취급
        if content and re.sub(r"<!--.*?-->", "", content, flags=re.S).strip():
            open_questions.append({"project": project, "content": content})
    return {"blockers": blockers, "open_questions": open_questions}


def detail(project, log_lines=50):
    _check_project_name(project)
    state_dir = os.path.join(QUEUE_ROOT, project)
    handoff = None
    try:
        with open(os.path.join(state_dir, "handoff.json")) as f:
            handoff = json.load(f)
    except (OSError, ValueError):
        pass
    log_tail, log_name = None, None
    logs = sorted(glob.glob(os.path.join(state_dir, "runs", "run-*.log")))
    if logs:
        log_name = os.path.basename(logs[-1])
        try:
            # 큰 로그 대비: 끝 64KB만 읽어 마지막 N줄 (2초 폴링용)
            with open(logs[-1], "rb") as f:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - 65536))
                chunk = f.read().decode(errors="replace")
            log_tail = "".join(chunk.splitlines(keepends=True)[-log_lines:])
        except OSError:
            pass
    return {"project": project, "handoff": handoff, "log_name": log_name, "log_tail": log_tail}


def _price(model):
    """모델별 API 종량제 단가 (입력$/M, 출력$/M) — run.sh·usage-report.sh와 동일."""
    m = model or ""
    if "opus" in m:
        return (5, 25)
    if "haiku" in m:
        return (1, 5)
    if "sonnet" in m:
        return (3, 15)
    if "glm" in m:
        return (0.6, 2.2)
    return (3, 15)


def usage():
    """전 프로젝트 토큰 사용량 합계(표시용, 읽기 전용).
    run.sh가 기록한 state/<project>/usage.tsv를 모두 합산한다. $는 API 환산가치(실청구 아님).
    행 형식: ts  run  round  role  model  input  output  cache_read  cache_create"""
    tin = tout = tcr = tcc = 0
    cost = 0.0
    for tsv in glob.glob(os.path.join(QUEUE_ROOT, "*", "usage.tsv")):
        try:
            with open(tsv) as f:
                for line in f:
                    cols = line.rstrip("\n").split("\t")
                    if len(cols) < 9 or cols[0] == "ts":
                        continue
                    try:
                        i, o, cr, cc = int(cols[5]), int(cols[6]), int(cols[7]), int(cols[8])
                    except ValueError:
                        continue
                    tin += i; tout += o; tcr += cr; tcc += cc
                    pin, pout = _price(cols[4])
                    cost += (i * pin + cr * pin * 0.1 + cc * pin * 1.25 + o * pout) / 1e6
        except OSError:
            continue
    return {
        "input": tin, "output": tout, "cache_read": tcr, "cache_create": tcc,
        "total": tin + tout + tcr + tcc, "cost": round(cost, 2),
    }


def usage_breakdown():
    """프로젝트별·일자별·프로젝트×일자 토큰 분해(대시보드용, 읽기 전용).
    state/<project>/usage.tsv 를 모두 읽어 집계한다. total.total 은 usage()['total'] 과 일치.
    $는 API 환산가치(실청구 아님). _price()·환산식은 usage()와 동일."""
    p_tok = {}; p_cost = {}; p_calls = {}; p_first = {}; p_last = {}
    d_tok = {}; d_cost = {}; d_calls = {}
    c_tok = {}; c_cost = {}
    ttok = 0; tcost = 0.0; tcalls = 0
    for tsv in glob.glob(os.path.join(QUEUE_ROOT, "*", "usage.tsv")):
        project = os.path.basename(os.path.dirname(tsv))
        try:
            with open(tsv) as f:
                for line in f:
                    cols = line.rstrip("\n").split("\t")
                    if len(cols) < 9 or cols[0] == "ts":
                        continue
                    try:
                        i, o, cr, cc = int(cols[5]), int(cols[6]), int(cols[7]), int(cols[8])
                    except ValueError:
                        continue
                    day = cols[0][:10]
                    tok = i + o + cr + cc
                    pin, pout = _price(cols[4])
                    c = (i * pin + cr * pin * 0.1 + cc * pin * 1.25 + o * pout) / 1e6
                    p_tok[project] = p_tok.get(project, 0) + tok
                    p_cost[project] = p_cost.get(project, 0.0) + c
                    p_calls[project] = p_calls.get(project, 0) + 1
                    if project not in p_first or day < p_first[project]:
                        p_first[project] = day
                    if project not in p_last or day > p_last[project]:
                        p_last[project] = day
                    d_tok[day] = d_tok.get(day, 0) + tok
                    d_cost[day] = d_cost.get(day, 0.0) + c
                    d_calls[day] = d_calls.get(day, 0) + 1
                    key = project + "|" + day
                    c_tok[key] = c_tok.get(key, 0) + tok
                    c_cost[key] = c_cost.get(key, 0.0) + c
                    ttok += tok; tcost += c; tcalls += 1
        except OSError:
            continue
    projects = sorted(
        ({"name": p, "total": p_tok[p], "cost": round(p_cost[p], 2),
          "calls": p_calls[p], "first": p_first[p], "last": p_last[p]}
         for p in p_tok),
        key=lambda r: r["cost"], reverse=True)
    days = sorted(
        ({"day": d, "total": d_tok[d], "cost": round(d_cost[d], 2), "calls": d_calls[d]}
         for d in d_tok),
        key=lambda r: r["day"])
    cells = {k: {"total": c_tok[k], "cost": round(c_cost[k], 2)} for k in c_tok}
    return {
        "total": {"total": ttok, "cost": round(tcost, 2), "calls": tcalls},
        "projects": projects, "days": days, "cells": cells,
    }


# ── CLI (테스트·수동 조작용) ──

def _cli(argv):
    def out(obj):
        print(json.dumps(obj, ensure_ascii=False))
    cmd = argv[0] if argv else "snapshot"
    args = argv[1:]
    if cmd == "add":
        out(add(args[0], args[1] if len(args) > 1 else "auto"))
    elif cmd == "remove":
        remove(args[0]); out({"ok": True})
    elif cmd == "reorder":
        reorder(args); out({"ok": True})
    elif cmd == "mode":
        set_mode(args[0], args[1]); out({"ok": True})
    elif cmd == "resume":
        resume(args[0]); out({"ok": True})
    elif cmd == "request":
        request(args[0], args[1]); out({"ok": True})
    elif cmd == "answer":
        out(answer(args[0], args[1] if len(args) > 1 else ""))
    elif cmd == "decisions":
        out(decisions())
    elif cmd == "snapshot":
        out(snapshot())
    elif cmd == "detail":
        out(detail(args[0]))
    elif cmd == "usage":
        out(usage())
    elif cmd == "usage_breakdown":
        out(usage_breakdown())
    else:
        print("사용: queue_ops.py add|remove|reorder|mode|resume|request|snapshot|detail|decisions|answer|usage|usage_breakdown ...", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(_cli(sys.argv[1:]))
    except OpError as e:
        print(f"❌ {e}", file=sys.stderr)
        sys.exit(1)
    except IndexError:
        print("❌ 인자 부족", file=sys.stderr)
        sys.exit(2)
