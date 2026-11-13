#!/usr/bin/env bash
# ui/queue_ops.py usage() — 전 프로젝트 토큰 합산·모델별 환산$·불량행 내성 검증
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PIPELINE_DIR="$TMP/olympus"
mkdir -p "$PIPELINE_DIR/state/alpha" "$PIPELINE_DIR/state/beta"
OPS="$ROOT/ui/queue_ops.py"
HDR='ts\trun\tround\trole\tmodel\tinput\toutput\tcache_read\tcache_create\n'
# usage 결과의 특정 필드 추출
uget(){ python3 "$OPS" usage | python3 -c 'import sys,json;print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

# 1) usage.tsv 전무 → 0 합계 (엣지)
assert_eq "0"   "$(uget total)" "tsv 없음 → total=0"
assert_eq "0.0" "$(uget cost)"  "tsv 없음 → cost=0"

# 2) alpha: opus 1M/0.5M + sonnet 2M/1M
{ printf "$HDR"
  printf '2026-07-09 10:00:00\tr1\tplan\tmetis\tclaude-opus-4\t1000000\t500000\t0\t0\n'
  printf '2026-07-09 10:05:00\tr1\t1\tbuilder\tclaude-sonnet-4\t2000000\t1000000\t0\t0\n'
} > "$PIPELINE_DIR/state/alpha/usage.tsv"
# opus cost=(1e6*5 + 0.5e6*25)/1e6=17.5 · sonnet=(2e6*3 + 1e6*15)/1e6=21 → 38.5
assert_eq "4500000" "$(uget total)" "alpha 토큰 합계"
assert_eq "3000000" "$(uget input)" "alpha 입력 합계"
assert_eq "38.5"    "$(uget cost)"  "alpha 모델별 환산$ 합계"

# 3) beta 추가: haiku(캐시 포함) + 불량행 2개(짧은 컬럼·정수아님) → 불량행 무시
{ printf "$HDR"
  printf '2026-07-09 11:00:00\tr1\t1\tbuilder\tclaude-haiku-4\t100000\t50000\t1000000\t200000\n'
  printf 'bad\trow\tshort\n'
  printf '2026-07-09 11:05:00\tr1\t1\tbuilder\tclaude-haiku-4\tNaN\t1\t2\t3\n'
} > "$PIPELINE_DIR/state/beta/usage.tsv"
# haiku cost=(1e5*1 + 1e6*0.1 + 2e5*1.25 + 5e4*5)/1e6=0.7 → 총 38.5+0.7=39.2
# beta 유효토큰=100000+50000+1000000+200000=1350000 → 총 4500000+1350000=5850000
assert_eq "5850000" "$(uget total)" "alpha+beta 합산(불량행 제외)"
assert_eq "39.2"    "$(uget cost)"  "다중 프로젝트 환산$ 합계"

# 4) 헤더 행은 집계에서 제외 (헤더만 있는 tsv는 0 기여)
printf "$HDR" > "$PIPELINE_DIR/state/alpha/usage.tsv"
assert_eq "1350000" "$(uget total)" "헤더만 남은 alpha → beta만 집계"

echo; echo "ui_usage: run=$TESTS_RUN fail=$TESTS_FAIL"; [ "$TESTS_FAIL" -eq 0 ]
