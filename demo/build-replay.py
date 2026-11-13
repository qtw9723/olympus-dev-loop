#!/usr/bin/env python3
"""demo/run-demo.sh의 실행 기록(DEMO_TRANSCRIPT)을 정적 재생 페이지 web/index.html로 만든다.
사용: mkdir -p demo/recorded && DEMO_TRANSCRIPT=demo/recorded/transcript.txt bash demo/run-demo.sh && python3 demo/build-replay.py
(demo/recorded/는 gitignore — 원본 기록엔 임시 경로가 섞여 있어 정규화한 web/index.html만 커밋한다)
"""
import html, re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "demo/recorded/transcript.txt"
raw = src.read_text(encoding="utf-8")

# 임시 경로·시각은 재현성과 가독성을 위해 정규화한다
raw = re.sub(r"/tmp/tmp\.[A-Za-z0-9]+", "/tmp/olympus-demo", raw)
raw = re.sub(r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}Z?", "<시각>", raw)
raw = re.sub(r"run-\d{8}-\d{6}\.log", "run-<시각>.log", raw)
raw = re.sub(r"(olympus/slugify-demo)-\d{8}-\d{6}", r"\1-<시각>", raw)
raw = re.sub(r"Ran 3 tests in [0-9.]+s", "Ran 3 tests in <t>s", raw)

m = re.search(r"===== run 1 \(exit (\d+)\) =====\n(.*?)\n===== human:.*?=====\n(.*?)===== run 2 \(exit (\d+)\) =====\n(.*)", raw, re.S)
if not m:
    sys.exit("transcript 형식을 읽지 못했습니다")
rc1, run1, _, rc2, run2 = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)

def block(title, text, open_=False):
    return f'<details{" open" if open_ else ""}><summary>{html.escape(title)}</summary><pre>{html.escape(text.strip())}</pre></details>'

def between(text, start, end=None):
    i = text.index(start)
    j = text.index(end, i) if end else len(text)
    return text[i:j]

gate_fail = between(run1, "--- round 1/4 : BUILDER", "--- round 1/4 : CRITIC")
escalation = between(run1, "🟠 사람 에스컬레이션", "처리 후 다시")
resume = between(run2, "↩️ 재개", "===== TASK")
green = between(run2, "--- round 1/4 : BUILDER", "===== 기획자")
final = between(run2, "✅ 백로그 전부 완료", "── 누적 변경 요약") + between(run2, "✅ AUTO_APPROVE")

page = f"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Olympus 데모 — 심판을 건드리면 사람을 부른다</title>
<meta name="description" content="Olympus 파이프라인이 구현 역할의 판정 파일 변경을 적발하고 사람 개입 후 재개하는 과정을 재생합니다. 실운영이 아닌 스크립트 데모입니다.">
<style>
:root{{--field:#2B3FF0;--ground:#F4F5FA;--ink:#10131F;--muted:#474F63;--rule:#C9CDDB;--code:#0D1019;--code-ink:#E8EAF3;--warn:#B42318;color-scheme:light}}
@media (prefers-color-scheme:dark){{:root{{--ground:#0D1019;--ink:#E8EAF3;--muted:#A5ACC2;--rule:#2A3042;--code:#05070C}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--ground);color:var(--ink);font:16px/1.75 system-ui,-apple-system,"Apple SD Gothic Neo","Noto Sans KR","Malgun Gothic",sans-serif;word-break:keep-all;overflow-wrap:break-word}}
.wrap{{max-width:920px;margin:0 auto;padding:0 24px}}
header{{background:var(--field);color:#fff;padding:48px 0 40px}}
h1{{margin:0 0 12px;font-size:clamp(28px,5vw,44px);line-height:1.2;text-wrap:balance}}
header p{{margin:0;max-width:40em}}
.tag{{display:inline-block;margin-bottom:16px;padding:4px 12px;border:1.5px solid #fff;font-weight:700;font-size:14px}}
section{{padding:40px 0;border-top:1px solid var(--rule)}}
section:first-of-type{{border-top:0}}
h2{{margin:0 0 8px;font-size:22px;line-height:1.4}}
section>.wrap>p{{margin:0 0 16px;max-width:42em;color:var(--muted)}}
details{{margin:12px 0;border:1px solid var(--rule)}}
summary{{padding:10px 14px;cursor:pointer;font-weight:600;min-height:44px;display:flex;align-items:center}}
pre{{margin:0;padding:16px;background:var(--code);color:var(--code-ink);overflow:auto;max-height:420px;font:13px/1.6 ui-monospace,Menlo,Consolas,monospace;white-space:pre}}
.callout{{padding:12px 16px;border-left:4px solid var(--warn);background:color-mix(in srgb,var(--warn) 8%,var(--ground));margin:16px 0}}
.callout b{{color:var(--warn)}}
footer{{padding:32px 0 56px;color:var(--muted);font-size:14px;border-top:1px solid var(--rule)}}
a{{color:var(--field)}}@media (prefers-color-scheme:dark){{a{{color:#9DB0FF}}}}
:focus-visible{{outline:3px solid var(--field);outline-offset:2px}}
</style>
</head>
<body>
<header><div class="wrap">
<span class="tag">실운영 아님 · 스크립트된 에이전트 응답</span>
<h1>심판 파일을 건드리면, 사람을 부릅니다</h1>
<p>Olympus의 <code>run.sh</code> 루프, verify 게이트, 핸드오프, 사람 에스컬레이션은 실제 코드 그대로 실행됩니다. 바뀌는 것은 역할 세션(claude)이 하는 행동뿐이고, 이 데모에서는 정해진 스크립트가 대신합니다. 그래서 API 키 없이 1분 안에 재현됩니다.</p>
</div></header>
<main>
<section><div class="wrap">
<h2>1. 테스트는 실패했는데 게이트는 green이다</h2>
<p>구현 역할이 실패하는 테스트를 통과시키려고 판정 파일 <code>verify.sh</code> 끝에 <code>|| true</code>를 붙였습니다. 아래 기록에서 테스트 3개가 FAIL인데 마지막 줄은 <code>VERIFY_EXIT=0</code>입니다. 게이트 숫자만 믿었다면 여기서 통과했을 겁니다.</p>
{block("run.sh 라운드 1: 구현 역할 호출과 게이트 결과", gate_fail, True)}
</div></section>
<section><div class="wrap">
<h2>2. 비평 역할이 diff에서 심판 변경을 적발한다</h2>
<p>비평 역할은 게이트 결과를 그대로 믿지 않고, 구현 역할의 변경분에 심판 파일이 들어 있는지 diff로 확인합니다. 들어 있으면 결함이 아니어도 반드시 사람에게 넘기도록 역할 문서에 규칙이 있고, <code>run.sh</code>는 <code>turn=human</code>을 보고 종료코드 {html.escape(rc1)}로 멈춥니다.</p>
<div class="callout"><b>자동 진행 중단.</b> 사유는 증거(diff)와 함께 critic-feedback.md에 남습니다.</div>
{block("사람에게 올라온 에스컬레이션", escalation, True)}
</div></section>
<section><div class="wrap">
<h2>3. 사람이 판정을 복구하고 재개한다</h2>
<p>사람이 한 일은 <code>git checkout -- verify.sh</code> 한 줄과 핸드오프 턴 되돌리기뿐입니다. 재실행하면 기획자는 재분석하지 않고 기존 상태에서 이어가며, 이전 작업 브랜치도 그대로 이어받습니다.</p>
{block("재개 직후", resume)}
{block("라운드 1: 구현 수정 → 진짜 verify green → 비평 green", green, True)}
{block("전체 완료, 승인, 머지", final)}
</div></section>
<section><div class="wrap">
<h2>전체 기록</h2>
<p>위 발췌의 원본입니다. 시각과 임시 경로만 정규화했습니다.</p>
{block("run 1 (종료코드 " + rc1 + ")", run1)}
{block("run 2 (종료코드 " + rc2 + ")", run2)}
</div></section>
</main>
<footer><div class="wrap">
직접 실행: <code>bash demo/run-demo.sh</code> (bash, git, jq, python3 필요). 이 저장소의 테스트 스위트에도 포함되어 있습니다.
</div></footer>
</body>
</html>
"""
out = root / "web/index.html"
out.write_text(page, encoding="utf-8")
print("wrote", out, len(page), "bytes")
