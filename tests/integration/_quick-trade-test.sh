#!/usr/bin/env bash
# _quick-trade-test.sh — Quick smoke test of full trade flow on testnet.
# Place buy → verify in orderbook → place matching sell → verify trade → check balance delta.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"

CHAIN_ENV="${CHAIN:-testnet}"
if [ "$CHAIN_ENV" = "mainnet" ] || [ "$CHAIN_ENV" = "local-mainnet" ]; then
    echo "${C_RED}refusing to run trade test on $CHAIN_ENV — set CHAIN=testnet${C_RESET}"
    exit 2
fi
export CHAIN="$CHAIN_ENV"

WALLET="${WALLET:-ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl}"
PAIR_ID="${PAIR_ID:-0}"     # OMNI/USDC
PRICE="${PRICE:-1.00}"
AMOUNT="${AMOUNT:-1}"
SUITE_TITLE="Quick Trade Test ($CHAIN, pair $PAIR_ID)"
print_header "$SUITE_TITLE"
echo "${C_DIM}wallet: $WALLET   pair: $PAIR_ID   price: $PRICE   amount: $AMOUNT${C_RESET}"

# Pre balance
resp=$(rpc "getbalance" "[\"$WALLET\"]")
BAL_PRE=$(json_get "$resp" ".result")
print_info "balance pre: $BAL_PRE"

# Pair info (sanity)
resp=$(rpc "exchange_pairInfo" "[$PAIR_ID]")
assert_ok "$resp" "exchange_pairInfo($PAIR_ID)"

# Place buy
echo
echo "${C_DIM}-- placing buy order --${C_RESET}"
buy_payload=$(printf '[{"pair_id":%d,"side":"buy","price":%s,"amount":%s,"owner":"%s"}]' "$PAIR_ID" "$PRICE" "$AMOUNT" "$WALLET")
resp=$(rpc "exchange_placeOrder" "$buy_payload")
assert_ok "$resp" "exchange_placeOrder buy"
BUY_ID=$(json_get "$resp" ".result.order_id")
[ -z "$BUY_ID" ] && BUY_ID=$(json_get "$resp" ".result.id")
print_info "buy order_id: ${BUY_ID:-<missing>}"
sleep 3

# Verify in orderbook
resp=$(rpc "exchange_listOrders" "[{\"pair_id\":$PAIR_ID,\"owner\":\"$WALLET\"}]")
assert_ok "$resp" "exchange_listOrders"
if [ -n "${BUY_ID:-}" ] && echo "$resp" | grep -q "$BUY_ID"; then
    print_pass "buy order visible in orderbook"
else
    print_fail "buy order missing from orderbook"
fi

# Place matching sell (immediate-or-cancel intent)
echo
echo "${C_DIM}-- placing matching sell --${C_RESET}"
sell_payload=$(printf '[{"pair_id":%d,"side":"sell","price":%s,"amount":%s,"owner":"%s"}]' "$PAIR_ID" "$PRICE" "$AMOUNT" "$WALLET")
resp=$(rpc "exchange_placeOrder" "$sell_payload")
assert_ok "$resp" "exchange_placeOrder sell"
SELL_ID=$(json_get "$resp" ".result.order_id")
[ -z "$SELL_ID" ] && SELL_ID=$(json_get "$resp" ".result.id")
print_info "sell order_id: ${SELL_ID:-<missing>}"
sleep 5

# Verify trade in recent
resp=$(rpc "exchange_getRecentTrades" "[{\"pair_id\":$PAIR_ID,\"limit\":10}]")
assert_ok "$resp" "exchange_getRecentTrades"
trade_count=$(echo "$resp" | grep -oE '"price"' | wc -l | tr -d ' ')
if [ "$trade_count" -gt 0 ]; then
    print_pass "recent trades non-empty (count=$trade_count)"
else
    print_fail "no recent trades" "buy/sell did not match"
fi

# Post balance — should differ by fees only (self-trade)
resp=$(rpc "getbalance" "[\"$WALLET\"]")
BAL_POST=$(json_get "$resp" ".result")
print_info "balance post: $BAL_POST"
delta=$(awk "BEGIN{print $BAL_PRE - $BAL_POST}")
print_info "net delta (fees expected small +ve): $delta"
if awk "BEGIN{exit !($delta >= -0.01 && $delta <= 1.0)}"; then
    print_pass "balance delta within fee tolerance"
else
    print_fail "balance delta outside tolerance" "delta=$delta (expected near 0 + fees)"
fi

# Cleanup any stragglers
[ -n "${BUY_ID:-}"  ] && rpc "exchange_cancelOrder" "[{\"order_id\":\"$BUY_ID\"}]"  >/dev/null
[ -n "${SELL_ID:-}" ] && rpc "exchange_cancelOrder" "[{\"order_id\":\"$SELL_ID\"}]" >/dev/null

finish
