# 순수 bash 어설션 (bats 미사용)
TESTS_RUN=0; TESTS_FAIL=0
fail(){ echo "  ✗ $1"; TESTS_FAIL=$((TESTS_FAIL+1)); }
pass(){ echo "  ✓ $1"; }
assert_eq(){ TESTS_RUN=$((TESTS_RUN+1)); if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 — expected [$1] got [$2]"; fi; }
assert_contains(){ TESTS_RUN=$((TESTS_RUN+1)); case "$1" in *"$2"*) pass "$3";; *) fail "$3 — [$1] does not contain [$2]";; esac; }
assert_not_contains(){ TESTS_RUN=$((TESTS_RUN+1)); case "$1" in *"$2"*) fail "$3 — [$2]가 포함됨";; *) pass "$3";; esac; }
