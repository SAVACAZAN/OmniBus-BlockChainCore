#!/usr/bin/env bash
# 08-htlc-swap.sh — Atomic swaps + HTLC (read-only)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="08 HTLC & Atomic Swaps"
print_header "$SUITE_TITLE"

ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"

# 1) swap_listOpen
resp=$(rpc "swap_listOpen" "[]")
assert_ok "$resp" "swap_listOpen"
swap_resp="$resp"

# 2) htlc_listByAddress
resp=$(rpc "htlc_listByAddress" "[{\"address\":\"$ADDR\"}]")
assert_ok "$resp" "htlc_listByAddress savacazan"

# 3) htlc_listPending
resp=$(rpc "htlc_listPending" "[]")
assert_ok "$resp" "htlc_listPending"

# 4) swap_status — pick first id from swap_listOpen, else skip
first_swap=""
if [ "$HAS_JQ" = "1" ]; then
    first_swap=$(echo "$swap_resp" | jq -r '.result[0].id // .result[0].swap_id // empty' 2>/dev/null)
else
    first_swap=$(echo "$swap_resp" | sed -n 's/.*"swap_id":"\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$first_swap" ]; then
        first_swap=$(echo "$swap_resp" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
    fi
fi

if [ -z "$first_swap" ]; then
    print_skip "swap_status" "no open swaps"
else
    resp=$(rpc "swap_status" "[{\"id\":\"$first_swap\"}]")
    err=$(json_get "$resp" ".error.message")
    if [ -n "$err" ]; then
        resp=$(rpc "swap_status" "[{\"swap_id\":\"$first_swap\"}]")
    fi
    assert_ok "$resp" "swap_status id=$first_swap"
fi

finish
