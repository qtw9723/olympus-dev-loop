#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
. "$DIR/helpers.sh"; . "$ROOT/remote.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1) 템플릿만 있고 답 없음 → 빈 문자열
cat > "$TMP/empty.md" <<'EOF'
## 질문
뭐 할까?

## 답변
<!-- 아래에 답을 쓰고 commit 하세요. approval이면 y 또는 n -->
EOF
assert_eq "" "$(_answer_from_file "$TMP/empty.md")" "템플릿만 있으면 빈 답"

# 2) 답이 채워짐 → 그 텍스트
cat > "$TMP/filled.md" <<'EOF'
## 질문
뭐 할까?

## 답변
<!-- 아래에 답을 쓰고 commit 하세요. approval이면 y 또는 n -->
그냥 A안으로 진행해
EOF
assert_eq "그냥 A안으로 진행해" "$(_answer_from_file "$TMP/filled.md")" "채워진 답 추출"

# 3) approval y
cat > "$TMP/appr.md" <<'EOF'
## 답변
<!-- 답 -->
y
EOF
assert_eq "y" "$(_answer_from_file "$TMP/appr.md")" "approval y 추출"

# 4) 선행 공백 하나(모바일 키보드) → trim되어 y
cat > "$TMP/leading_space.md" <<'EOF'
## 답변
<!-- 답 -->
 y
EOF
assert_eq "y" "$(_answer_from_file "$TMP/leading_space.md")" "선행 공백 1개 trim"

# 5) 선행 공백 여러 개 → trim되어 본문만
cat > "$TMP/leading_spaces.md" <<'EOF'
## 답변
<!-- 답 -->
   approve 진행
EOF
assert_eq "approve 진행" "$(_answer_from_file "$TMP/leading_spaces.md")" "선행 공백 여러개 trim"

[ "${TESTS_FAIL:-0}" -eq 0 ]
