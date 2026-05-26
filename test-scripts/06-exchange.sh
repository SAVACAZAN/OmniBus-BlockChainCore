#!/usr/bin/env bash
# 06-exchange.sh — Native DEX: pairs, orders, trades
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="06 Exchange (DEX)"
print_header "$SUITE_TITLE"

ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"

# 1) exchange_listPairs
resp=$(rpc "exchange_listPairs" "[]")
assert_ok "$resp" "exchange_listPairs"
rc=$?
if [ "$rc" = "0" ]; then
    for f in pair_id base quote; do
        if echo "$resp" | grep -q "\"$f\""; then
            print_pass "  field present: $f"
        else
            print_skip "  field present: $f" "no pairs configured on $CHAIN"
        fi
    done
fi

# 2) exchange_pairInfo for pair_id 0
resp=$(rpc "exchange_pairInfo" '[{"pair_id":0}]')
assert_ok "$resp" "exchange_pairInfo pair_id=0"

# 3) Iterate pair_ids 1..6
for pid in 1 2 3 4 5 6; do
    resp=$(rpc "exchange_pairInfo" "[{\"pair_id\":$pid}]")
    err=$(json_get "$resp" ".error.message")
    if [ -n "$err" ] && echo "$err" | grep -qiE "not found|unknown pair|invalid"; then
        print_skip "exchange_pairInfo pair_id=$pid" "$err"
    else
        assert_ok "$resp" "exchange_pairInfo pair_id=$pid"
    fi
done

# 4) exchange_listOrders for pair_id 0
resp=$(rpc "exchange_listOrders" '[{"pair_id":0}]')
assert_ok "$resp" "exchange_listOrders pair_id=0"

# 5) exchange_getUserOrders
resp=$(rpc "exchange_getUserOrders" "[{\"trader\":\"$ADDR\"}]")
assert_ok "$resp" "exchange_getUserOrders trader=savacazan"

# 6) exchange_getRecentTrades pair_id=0 limit=10
resp=$(rpc "exchange_getRecentTrades" '[{"pair_id":0,"limit":10}]')
assert_ok "$resp" "exchange_getRecentTrades pair_id=0 limit=10"

finish
