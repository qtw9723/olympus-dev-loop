#!/usr/bin/env bash
# ui/queue_ops.py usage_breakdown() — 프로젝트별·일자별·매트릭스 분해 + 총계 정합성 검증
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/state/alpha" "$PIPELINE_DIR/state/beta"
OPS="$ROOT/ui/queue_ops.py"
HDR='ts\trun\tround\trole\tmodel\tinput\toutput\tcache_read\tcache_create\n'
# breakdown 결과에 파이썬 식(변수 d) 적용해 값 추출
bget(){ python3 "$OPS" usage_breakdown | python3 -c 'import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))' "$1"; }
# usage() total 과 breakdown total 정합성 비교용
uget(){ python3 "$OPS" usage | python3 -c 'import sys,json;print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

# 1) 빈 상태 (엣지) — 예외 없이 빈 구조
assert_eq "0" "$(bget 'd["total"]["total"]')" "빈 상태 → total.total=0"
assert_eq "0" "$(bget 'len(d["projects"])')"  "빈 상태 → projects 없음"
assert_eq "0" "$(bget 'len(d["cells"])')"     "빈 상태 → cells 없음"

# 2) 데이터 주입: alpha(2일치), beta(1일)
{ printf "$HDR"
  printf '2026-07-09 10:00:00\tr1\tplan\tmetis\tclaude-opus-4\t1000000\t500000\t0\t0\n'
  printf '2026-07-10 10:05:00\tr1\t1\tbuilder\tclaude-sonnet-4\t2000000\t1000000\t0\t0\n'
} > "$PIPELINE_DIR/state/alpha/usage.tsv"
{ printf "$HDR"
  printf '2026-07-09 11:00:00\tr1\t1\tbuilder\tclaude-haiku-4\t100000\t50000\t1000000\t200000\n'
  printf 'bad\trow\tshort\n'
} > "$PIPELINE_DIR/state/beta/usage.tsv"
# 토큰: alpha=1.5M+3M=4.5M, beta=1.35M → 총 5.85M, 호출 3(불량행 제외)
# 비용: opus 17.5 + sonnet 21 + haiku 0.7 = 39.2

# 총계 + usage() 정합성
assert_eq "5850000" "$(bget 'd["total"]["total"]')" "total.total 합계"
assert_eq "3"       "$(bget 'd["total"]["calls"]')"  "total.calls(불량행 제외)"
assert_eq "$(uget total)" "$(bget 'd["total"]["total"]')" "usage()와 breakdown 총계 일치"

# 분해 합산 = 총계 (회귀 방지) — bget의 python 식은 작은따옴표로 감싸 큰따옴표 키 그대로 사용 가능
assert_eq "5850000" "$(bget 'sum(p["total"] for p in d["projects"])')" "Σ프로젝트 = 총계"
assert_eq "5850000" "$(bget 'sum(x["total"] for x in d["days"])')"     "Σ일자 = 총계"
assert_eq "5850000" "$(bget 'sum(c["total"] for c in d["cells"].values())')" "Σ매트릭스셀 = 총계"

# 프로젝트: cost 내림차순 → alpha 먼저, 기간·합계
assert_eq "alpha"      "$(bget 'd["projects"][0]["name"]')"  "projects[0]=alpha(최고비용)"
assert_eq "4500000"    "$(bget 'd["projects"][0]["total"]')" "alpha 토큰 합계"
assert_eq "2026-07-09" "$(bget 'd["projects"][0]["first"]')" "alpha first"
assert_eq "2026-07-10" "$(bget 'd["projects"][0]["last"]')"  "alpha last"

# 일자: 오름차순, 07-09 = alpha opus 1.5M + beta 1.35M = 2.85M
assert_eq "2026-07-09" "$(bget 'd["days"][0]["day"]')"   "days 오름차순 첫날"
assert_eq "2850000"    "$(bget 'd["days"][0]["total"]')" "07-09 일자 합계"
assert_eq "3000000"    "$(bget 'd["days"][1]["total"]')" "07-10 일자 합계"

# 매트릭스 셀 + 합산
assert_eq "3000000" "$(bget 'd["cells"]["alpha|2026-07-10"]["total"]')" "매트릭스 셀 alpha×07-10"

# 비용 + 호출 수 검증
assert_eq "39.2" "$(bget 'd["total"]["cost"]')" "total.cost 합계"
assert_eq "3" "$(bget 'd["total"]["calls"]')" "total.calls 합계"
assert_eq "38.5" "$(bget 'd["projects"][0]["cost"]')" "projects[0] alpha cost"
assert_eq "2" "$(bget 'd["projects"][0]["calls"]')" "projects[0] alpha calls"
assert_eq "0.7" "$(bget 'd["projects"][1]["cost"]')" "projects[1] beta cost"
assert_eq "1" "$(bget 'd["projects"][1]["calls"]')" "projects[1] beta calls"
assert_eq "18.2" "$(bget 'd["days"][0]["cost"]')" "days[0] 2026-07-09 cost"
assert_eq "2" "$(bget 'd["days"][0]["calls"]')" "days[0] 2026-07-09 calls"
assert_eq "21.0" "$(bget 'd["days"][1]["cost"]')" "days[1] 2026-07-10 cost"
assert_eq "1" "$(bget 'd["days"][1]["calls"]')" "days[1] 2026-07-10 calls"
assert_eq "17.5" "$(bget 'd["cells"]["alpha|2026-07-09"]["cost"]')" "cells alpha×2026-07-09 cost"
assert_eq "21.0" "$(bget 'd["cells"]["alpha|2026-07-10"]["cost"]')" "cells alpha×2026-07-10 cost"
assert_eq "0.7" "$(bget 'd["cells"]["beta|2026-07-09"]["cost"]')" "cells beta×2026-07-09 cost"

echo; echo "ui_usage_breakdown: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
