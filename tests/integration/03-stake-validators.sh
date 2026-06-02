#!/usr/bin/env bash
# 03-stake-validators.sh — Read-only stake/validator/slash queries
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="03 Stake & Validators"
print_header "$SUITE_TITLE"

ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"

# 1) getstake for known address
resp=$(rpc "getstake" "[\"$ADDR\"]")
assert_ok "$resp" "getstake (savacazan #0)"

# 2) getstakers
resp=$(rpc "getstakers" "[]")
assert_ok "$resp" "getstakers"

# 3) getvalidatorsv2
resp=$(rpc "getvalidatorsv2" "[]")
assert_ok "$resp" "getvalidatorsv2"
rc=$?
if [ "$rc" = "0" ]; then
    # shape probe
    for f in address tier; do
        if echo "$resp" | grep -q "\"$f\""; then
            print_pass "  field present: $f"
        else
            print_skip "  field present: $f" "may be empty list"
        fi
    done
fi

# 4) getslashevents
resp=$(rpc "getslashevents" "[]")
assert_ok "$resp" "getslashevents"

# 5) getslashevents with limit
resp=$(rpc "getslashevents" '[{"limit":10}]')
assert_ok "$resp" "getslashevents limit=10"

finish
