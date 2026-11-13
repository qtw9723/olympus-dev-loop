#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"; . "$ROOT/remote.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "정말 이대로 머지할까?" > "$TMP/body.txt"
_write_pending "$TMP/out.md" "20260702-153000" "approval" "최종 승인" "$TMP/body.txt"
OUT="$(cat "$TMP/out.md")"
assert_contains "$OUT" "id: 20260702-153000" "id frontmatter"
assert_contains "$OUT" "type: approval" "type frontmatter"
assert_contains "$OUT" "## 질문" "질문 헤더"
assert_contains "$OUT" "정말 이대로 머지할까?" "질문 본문 포함"
assert_contains "$OUT" "## 답변" "답변 헤더"
assert_contains "$OUT" "<!--" "답변 템플릿 주석"
# 방금 쓴 파일엔 아직 답이 없어야 함(추출 시 빈 문자열)
assert_eq "" "$(_answer_from_file "$TMP/out.md")" "새 pending은 답 비어있음"

[ "${TESTS_FAIL:-0}" -eq 0 ]
