#!/usr/bin/env bash
# inbox_imap.py --parse : 답장 본문 → y/n/빈줄. fragile 파싱을 네트워크 없이 검증.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

parse(){ python3 "$ROOT/inbox_imap.py" --parse "$1"; }

# 1) 상단 y + 인용문 → y
printf 'y\n\nOn Thu, Jul 3 2026 at 10:00, Olympus <x@x> wrote:\n> 머지 승인?\n> y 또는 n\n' > "$TMP/a"
assert_eq "y" "$(parse "$TMP/a")" "상단 y + 인용 → y"

# 2) 상단 한글 '승인' + 인용문 → y
printf '승인\n\n> 전체 개발 완료. 승인하려면 y\n' > "$TMP/b"
assert_eq "y" "$(parse "$TMP/b")" "상단 승인 + 인용 → y"

# 3) 상단 '거부' → n
printf '거부\n\n2026-07-03 님이 작성:\n> 승인?\n' > "$TMP/c"
assert_eq "n" "$(parse "$TMP/c")" "상단 거부 → n"

# 4) 상단 'n' → n
printf 'n\n' > "$TMP/d"
assert_eq "n" "$(parse "$TMP/d")" "상단 n → n"

# 5) 인용부에만 키워드(상단은 안내문뿐) → 무매칭(빈줄)
printf '전체 개발 완료 + verify green. 승인하려면 첫 줄에 y.\n\n> y\n> 승인\n' > "$TMP/e"
assert_eq "" "$(parse "$TMP/e")" "인용부 속 키워드는 무매칭"

# 6) top-post 빈줄 뒤 키워드 → 매칭
printf '\n\n  y  \n\n> 이전 내용\n' > "$TMP/f"
assert_eq "y" "$(parse "$TMP/f")" "선행 빈줄 + trim y → y"

# 7) 대소문자 YES / Y → y
printf 'YES\n' > "$TMP/g";  assert_eq "y" "$(parse "$TMP/g")" "YES → y"
printf 'Y\n'   > "$TMP/h";  assert_eq "y" "$(parse "$TMP/h")" "Y → y"

# 8) 무관한 문장 → 무매칭
printf '고마워요 나중에 볼게요\n' > "$TMP/i"
assert_eq "" "$(parse "$TMP/i")" "일반 문장 → 무매칭"

# 9) 영문 approve / reject
printf 'approve\n' > "$TMP/j"; assert_eq "y" "$(parse "$TMP/j")" "approve → y"
printf 'reject\n' > "$TMP/k"; assert_eq "n" "$(parse "$TMP/k")" "reject → n"

# 10) HTML-only 본문(태그 제거 후 첫 줄 키워드) → 매칭
printf '<div dir="ltr">y</div>\n<blockquote>&gt; 승인?</blockquote>\n' > "$TMP/l"
assert_eq "y" "$(parse "$TMP/l")" "HTML-only y → y"

# 11) Outlook 구분선(______) 위 키워드 → 매칭, 아래는 무시
printf 'n\n________________________________\n보낸 사람: Olympus\ny 승인\n' > "$TMP/m"
assert_eq "n" "$(parse "$TMP/m")" "Outlook 구분선 위 n → n"

# 12) 키워드가 문장 일부면(whole-line 아님) 무매칭
printf 'y 라고 답할게요\n' > "$TMP/n"
assert_eq "" "$(parse "$TMP/n")" "whole-line 아니면 무매칭"

[ "${TESTS_FAIL:-0}" -eq 0 ]
