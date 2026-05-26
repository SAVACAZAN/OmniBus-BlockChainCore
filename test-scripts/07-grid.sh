#!/usr/bin/env bash
# 07-grid.sh — Grid trading bots (read-only)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="07 Grid Trading"
print_header "$SUITE_TITLE"

# 1) grid_list
resp=$(rpc "grid_list" "[]")
assert_ok "$resp" "grid_list"
rc=$?

# 2) grid_status — pick first id from response, else skip
if [ "$rc" = "0" ]; then
    first_id=""
    if [ "$HAS_JQ" = "1" ]; then
        first_id=$(echo "$resp" | jq -r '.result[0].id // .result[0].grid_id // empty' 2>/dev/null)
    else
        first_id=$(echo "$resp" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)
        if [ -z "$first_id" ]; then
            first_id=$(echo "$resp" | sed -n 's/.*"grid_id":\([0-9]*\).*/\1/p' | head -1)
        fi
    fi

    if [ -z "$first_id" ]; then
        print_skip "grid_status" "no grids returned"
    else
        resp2=$(rpc "grid_status" "[{\"id\":$first_id}]")
        err=$(json_get "$resp2" ".error.message")
        if [ -n "$err" ]; then
            # try grid_id key shape
            resp2=$(rpc "grid_status" "[{\"grid_id\":$first_id}]")
        fi
        assert_ok "$resp2" "grid_status id=$first_id"
    fi
else
    print_skip "grid_status" "grid_list failed"
fi

finish
