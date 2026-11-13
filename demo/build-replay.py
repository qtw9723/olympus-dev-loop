#!/usr/bin/env python3
"""demo/run-demo.sh의 실행 기록(DEMO_TRANSCRIPT)을 정적 인포그래픽 페이지 web/index.html로 만든다.
사용: mkdir -p demo/recorded && DEMO_TRANSCRIPT=demo/recorded/transcript.txt bash demo/run-demo.sh && python3 demo/build-replay.py
(demo/recorded/는 gitignore — 원본 기록엔 임시 경로가 섞여 있어 정규화한 web/index.html만 커밋한다)
"""
import html, re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "demo/recorded/transcript.txt"
raw = src.read_text(encoding="utf-8")

# 임시 경로·시각 정규화
raw = re.sub(r"/tmp/tmp\.[A-Za-z0-9]+", "/tmp/olympus-demo", raw)
raw = re.sub(r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}Z?", "<시각>", raw)
raw = re.sub(r"run-\d{8}-\d{6}\.log", "run-<시각>.log", raw)
raw = re.sub(r"(olympus/slugify-demo)-\d{8}-\d{6}", r"\1-<시각>", raw)
raw = re.sub(r"Ran 3 tests in [0-9.]+s", "Ran 3 tests in <t>s", raw)

m = re.search(r"===== run 1 \(exit (\d+)\) =====\n(.*?)\n===== human:.*?=====\n(.*?)===== run 2 \(exit (\d+)\) =====\n(.*)", raw, re.S)
if not m:
    sys.exit("transcript 형식을 읽지 못했습니다")
rc1, run1, rc2, run2 = m.group(1), m.group(2), m.group(4), m.group(5)
e = html.escape

def tests(text):  # 테스트 줄 → [(이름, 결과)], 같은 이름은 마지막 결과만
    d = {}
    for n, r in re.findall(r"^(test_\w+) \(.*?\) \.\.\. (\w+)$", text, re.M):
        d[n] = r
    return list(d.items())

t1 = tests(run1)
t2 = tests(run2)
exit1 = re.findall(r"VERIFY_EXIT=(\d+)", run1)[0]
exit2 = re.findall(r"VERIFY_EXIT=(\d+)", run2)[0]
diff_minus = re.search(r"^\s+-(python3 .*)$", run1, re.M).group(1)
diff_plus = re.search(r"^\s+\+(python3 .*)$", run1, re.M).group(1)
assert t1 and t2 and all(r == "FAIL" for _, r in t1) and all(r == "ok" for _, r in t2), "기록이 시나리오와 다릅니다"

def rows(ts):
    out = ""
    for name, res in ts:
        cls = "fail" if res == "FAIL" else "ok"
        out += f'<li class="{cls}"><span class="res">{e(res)}</span><span>{e(name)}</span></li>'
    return out

def node(kind, label, sub="", bad=False):
    tag = {"llm": "LLM", "code": "코드", "ppl": "사람"}[kind]
    cls = {"llm": "st llm", "code": "st", "ppl": "st ppl"}[kind] + (" bad" if bad else "")
    return f'<li><span class="{cls}"><small>{tag}</small>{label}{("<br>" + sub) if sub else ""}</span></li>'

def lane(items):
    return '<ol class="lane">' + "".join(node(*i) if len(i) < 5 else node(i[0], i[1], i[2], i[3]) for i in items) + "</ol>"

legend = '<ul class="legend" aria-label="범례"><li><span class="sw llm"></span>LLM (데모에선 스크립트)</li><li><span class="sw"></span>코드 (실제 실행)</li><li><span class="sw ppl"></span>사람</li><li><span class="sw bad"></span>문제 지점</li></ul>'

pipeline = lane([("ppl", "스펙 폴더"), ("llm", "계획", "Metis"), ("llm", "구현", "Hephaestus"), ("code", "verify.sh", "심판"), ("llm", "비평", "Momus"), ("ppl", "사람 승인", "1회")])
run1_lane = lane([("llm", "기획자", "작업 1개로 분해"), ("llm", "구현", "verify.sh에 || true", True), ("code", "게이트", f"VERIFY_EXIT={exit1}"), ("llm", "비평", "심판 변경 적발"), ("code", "run.sh", f"중단 · exit {rc1}", True)])
human_lane = lane([("ppl", "심판 파일 원복", "git checkout -- verify.sh")])
run2_lane = lane([("code", "run.sh", "같은 브랜치 재개"), ("llm", "구현", "코드 수정"), ("code", "게이트", f"테스트 {len(t2)}개 ok"), ("llm", "비평", "green"), ("code", "머지", "main")])

def block(title, text, open_=False):
    return f'<details{" open" if open_ else ""}><summary>{e(title)}</summary><pre>{e(text.strip())}</pre></details>'


def mini(items):
    return lane(items)

str1 = mini([("ppl", "내 PC", "Claude Code 로그인"), ("code", "claude -p", "헤드리스 호출"), ("llm", "구독 플랜", "API 키 0")]) 
str2 = mini([("code", "run.sh", "승인 메일 발송"), ("ppl", "외부(폰)", "답장 y/n"), ("code", "IMAP 폴링", "감지 → 재개")])

strengths = f'''<section class="hi"><div class="wrap">
<h2>Olympus의 강점 2가지</h2>
<div class="two">
<div class="big"><span class="num">1</span><h3>API 키 없이, 구독 플랜으로</h3><p>로컬에 로그인된 Claude Code를 헤드리스로 호출합니다. 토큰 한도에 걸리면 자동으로 기다렸다 이어갑니다.</p>{str1}</div>
<div class="big"><span class="num">2</span><h3>메일로 보고받고, 메일로 지시</h3><p>자리를 비워도 메일 답장 한 줄(y/n)로 승인합니다. 밖에서도 개발이 이어집니다.</p>{str2}</div>
</div>
</div></section>'''

page = f"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Olympus 데모 — 심판을 건드리면 사람을 부른다</title>
<meta name="description" content="Olympus 파이프라인이 구현 역할의 판정 파일 변경을 적발하고 사람 개입 후 재개하는 과정을 한눈에 보여줍니다. 실운영이 아닌 스크립트 데모입니다.">
<style>
:root{{--field:#2B3FF0;--on-field:#fff;--ground:#F4F5FA;--ink:#10131F;--muted:#474F63;--rule:#C9CDDB;--link:#2B3FF0;--warn:#B42318;--good:#05603A;--code:#0D1019;--code-ink:#E8EAF3;color-scheme:light}}
@media (prefers-color-scheme:dark){{:root{{--ground:#0D1019;--ink:#E8EAF3;--muted:#A5ACC2;--rule:#2A3042;--link:#9DB0FF;--warn:#FF8A80;--good:#6CE9A6;--code:#05070C}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--ground);color:var(--ink);font:16px/1.7 system-ui,-apple-system,"Apple SD Gothic Neo","Noto Sans KR","Malgun Gothic",sans-serif;word-break:keep-all;overflow-wrap:break-word}}
.wrap{{max-width:980px;margin:0 auto;padding:0 24px}}
header{{background:var(--field);color:var(--on-field);padding:44px 0 36px}}
h1{{margin:0 0 10px;font-size:clamp(28px,5vw,46px);line-height:1.2;text-wrap:balance}}
header p{{margin:0;max-width:38em}}
.tag{{display:inline-block;margin-bottom:14px;padding:4px 12px;border:1.5px solid var(--on-field);font-weight:700;font-size:14px}}
section{{padding:36px 0;border-top:1px solid var(--rule)}}
section:first-of-type{{border-top:0}}
h2{{margin:0 0 6px;font-size:26px;line-height:1.4}}
.cap{{margin:0 0 18px;color:var(--muted);max-width:40em;font-size:15px}}
.legend{{display:flex;flex-wrap:wrap;gap:6px 18px;margin:0 0 12px;padding:0;list-style:none;font-size:13px;color:var(--muted)}}
.legend li{{display:flex;align-items:center;gap:8px}}
.sw{{width:22px;height:14px;border:1.5px solid var(--link);flex:none}}
.sw.llm{{background:var(--field);border-color:var(--field)}}
.sw.ppl{{border-style:dashed;border-color:var(--muted)}}
.sw.bad{{border-color:var(--warn);border-width:2.5px}}
.lane{{list-style:none;margin:0 0 6px;padding:0;display:flex;align-items:stretch}}
.lane li{{display:flex;align-items:center;flex:1 1 0;min-width:0}}
.lane li:not(:first-child)::before{{content:"";width:16px;height:10px;margin:0 3px;flex:none;background:var(--muted);-webkit-mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 34 10'%3E%3Cpath d='M0 5h31M27 1l5 4-5 4' fill='none' stroke='black' stroke-width='1.4'/%3E%3C/svg%3E") center/contain no-repeat;mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 34 10'%3E%3Cpath d='M0 5h31M27 1l5 4-5 4' fill='none' stroke='black' stroke-width='1.4'/%3E%3C/svg%3E") center/contain no-repeat}}
.st{{display:block;width:100%;height:100%;padding:9px 10px;border:1.5px solid var(--link);font-size:15px;font-weight:500;line-height:1.35}}
.st small{{display:block;font-size:12px;font-weight:700;letter-spacing:.02em}}
.st.llm{{background:var(--field);border-color:var(--field);color:var(--on-field)}}
.st.ppl{{border-style:dashed;border-color:var(--muted);color:var(--muted)}}
.st.bad{{border:3px solid var(--warn)}}
.hi{{background:color-mix(in srgb,var(--field) 7%,var(--ground))}}
.two{{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:18px;margin-top:14px}}
.big{{border:2px solid var(--field);background:var(--ground);padding:22px 20px}}
.big .num{{display:inline-grid;place-items:center;width:38px;height:38px;background:var(--field);color:var(--on-field);font-weight:800;font-size:20px;margin-bottom:10px}}
.big h3{{margin:0 0 8px;font-size:22px;line-height:1.35}}
.big p{{margin:0 0 16px;color:var(--muted);font-size:16px}}
.big .lane{{margin:0}}
.row{{margin:0 0 22px}}
.row h3{{margin:0 0 8px;font-size:14px;color:var(--muted);display:flex;gap:10px;align-items:baseline}}
.row h3 b{{color:var(--ink);font-size:16px}}
.vs{{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px}}
.card{{border:1.5px solid var(--rule);padding:16px}}
.card.bad{{border-color:var(--warn)}}.card.good{{border-color:var(--good)}}
.card h3{{margin:0 0 10px;font-size:15px}}
.card ul{{list-style:none;margin:0 0 12px;padding:0;display:grid;gap:6px}}
.card li{{display:flex;gap:10px;align-items:center;font:13px/1.4 ui-monospace,Menlo,Consolas,monospace}}
.res{{flex:none;min-width:3.4em;text-align:center;padding:1px 6px;font-weight:700;border:1.5px solid}}
li.fail .res{{color:var(--warn);border-color:var(--warn)}}
li.ok .res{{color:var(--good);border-color:var(--good)}}
.exit{{display:flex;justify-content:space-between;align-items:baseline;gap:10px;padding-top:10px;border-top:1px solid var(--rule);font-size:14px}}
.exit code{{font-weight:700;font-size:15px}}
.exit .why{{color:var(--muted);font-size:13px}}
.card.bad .exit code{{color:var(--warn)}}.card.good .exit code{{color:var(--good)}}
.diff{{margin:0;background:var(--code);color:var(--code-ink);font:13px/1.7 ui-monospace,Menlo,Consolas,monospace;padding:14px 16px;overflow:auto}}
.diff .m{{color:#FF8A80}}.diff .p{{color:#6CE9A6}}.diff .c{{color:#A5ACC2}}
.checks{{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px}}
.checks li{{border:1.5px solid var(--good);padding:8px 12px;font-size:14px;display:flex;gap:10px;align-items:center}}
.checks .res{{color:var(--good);border-color:var(--good);font-size:12px;font-family:ui-monospace,Menlo,Consolas,monospace}}
details{{margin:12px 0;border:1px solid var(--rule)}}
summary{{padding:10px 14px;cursor:pointer;font-weight:600;min-height:44px;display:flex;align-items:center}}
pre{{margin:0;padding:16px;background:var(--code);color:var(--code-ink);overflow:auto;max-height:420px;font:13px/1.6 ui-monospace,Menlo,Consolas,monospace;white-space:pre}}
footer{{padding:28px 0 56px;color:var(--muted);font-size:14px;border-top:1px solid var(--rule)}}
:focus-visible{{outline:3px solid var(--link);outline-offset:2px}}
@media (max-width:820px){{
  .lane{{flex-direction:column;align-items:stretch}}
  .lane li{{flex-direction:column;align-items:stretch;flex:none}}
  .lane li:not(:first-child)::before{{width:10px;height:18px;margin:2px 0 2px 18px;-webkit-mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 34'%3E%3Cpath d='M5 0v31M1 27l4 5 4-5' fill='none' stroke='black' stroke-width='1.4'/%3E%3C/svg%3E") center/contain no-repeat;mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 34'%3E%3Cpath d='M5 0v31M1 27l4 5 4-5' fill='none' stroke='black' stroke-width='1.4'/%3E%3C/svg%3E") center/contain no-repeat}}
  .st{{font-size:14.5px;padding:8px 12px}}
  .vs,.two{{grid-template-columns:1fr}}
}}
</style>
</head>
<body>
<header><div class="wrap">
<span class="tag">실운영 아님 · 스크립트된 에이전트 응답</span>
<h1>심판 파일을 건드리면, 사람을 부릅니다</h1>
<p>LLM 역할만 스크립트로 대신하고, run.sh 루프와 verify 게이트는 실제 코드 그대로 돌린 기록입니다.</p>
</div></header>
<main>
{strengths}
<section><div class="wrap">
<h2>파이프라인</h2>
<p class="cap">합격은 LLM의 말이 아니라 실행되는 verify.sh가 정합니다. 사람 승인은 전체가 끝난 뒤 한 번입니다.</p>
{legend}
{pipeline}
</div></section>
<section><div class="wrap">
<h2>이번 실행에서 일어난 일</h2>
<p class="cap">구현 역할이 실패하는 테스트를 숨기려고 판정 파일을 고치는 시나리오입니다.</p>
<div class="row"><h3><b>실행 1</b>종료코드 {e(rc1)}</h3>{run1_lane}</div>
<div class="row"><h3><b>사람 개입</b></h3>{human_lane}</div>
<div class="row"><h3><b>실행 2</b>종료코드 {e(rc2)}</h3>{run2_lane}</div>
</div></section>
<section><div class="wrap">
<h2>가짜 green과 진짜 green</h2>
<p class="cap">두 게이트의 종료 신호는 똑같이 VERIFY_EXIT={e(exit1)}입니다. 달라진 건 테스트 결과와, 판정 파일이 바뀌었는지뿐입니다.</p>
<div class="vs">
<div class="card bad"><h3>실행 1 — 게이트</h3><ul>{rows(t1)}</ul><div class="exit"><code>VERIFY_EXIT={e(exit1)}</code><span class="why">verify.sh가 약화돼 실패가 가려짐</span></div></div>
<div class="card good"><h3>실행 2 — 게이트</h3><ul>{rows(t2)}</ul><div class="exit"><code>VERIFY_EXIT={e(exit2)}</code><span class="why">판정 파일은 원본 그대로</span></div></div>
</div>
</div></section>
<section><div class="wrap">
<h2>비평 역할이 잡은 증거</h2>
<p class="cap">구현 변경분에 심판 파일이 들어 있으면 결함이 아니어도 사람에게 넘기도록 역할 문서에 규칙이 있습니다.</p>
<pre class="diff"><span class="c">verify.sh</span>
<span class="m">- {e(diff_minus)}</span>
<span class="p">+ {e(diff_plus)}</span></pre>
</div></section>
<section><div class="wrap">
<h2>검증된 항목</h2>
<p class="cap">데모 스크립트가 끝에서 자동으로 확인하는 항목입니다. 테스트 스위트에도 포함돼 있습니다.</p>
<ul class="checks">
<li><span class="res">PASS</span>실행 1이 사람 에스컬레이션으로 중단</li>
<li><span class="res">PASS</span>약화된 게이트가 green으로 보고</li>
<li><span class="res">PASS</span>비평 피드백에 심판 변경 기록</li>
<li><span class="res">PASS</span>재개 후 정상 종료</li>
<li><span class="res">PASS</span>최종 verify green</li>
<li><span class="res">PASS</span>심판 파일이 최초 커밋과 동일</li>
<li><span class="res">PASS</span>작업 브랜치가 main에 머지</li>
</ul>
</div></section>
<section><div class="wrap">
<h2>원본 기록</h2>
<p class="cap">시각과 임시 경로만 정규화했습니다.</p>
{block("실행 1 (종료코드 " + rc1 + ")", run1)}
{block("실행 2 (종료코드 " + rc2 + ")", run2)}
</div></section>
</main>
<footer><div class="wrap">직접 실행: <code>bash demo/run-demo.sh</code> (bash, git, jq, python3 필요)</div></footer>
</body>
</html>
"""
out = root / "web/index.html"
out.write_text(page, encoding="utf-8")
print("wrote", out, len(page), "bytes")
