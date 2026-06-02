#!/usr/bin/env bash
# _quick-stake-test.sh — Quick regression for stake/unstake balance lock.
# TESTNET ONLY by design (refuses to run on mainnet).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"

# ---- safety: never run on mainnet ----
CHAIN_ENV="${CHAIN:-testnet}"
if [ "$CHAIN_ENV" = "mainnet" ] || [ "$CHAIN_ENV" = "local-mainnet" ]; then
    echo "${C_RED}refusing to run stake test on $CHAIN_ENV — set CHAIN=testnet${C_RESET}"
    exit 2
fi
export CHAIN="$CHAIN_ENV"

WALLET="${WALLET:-ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl}"
AMOUNT="${AMOUNT:-11}"
SUITE_TITLE="Quick Stake Test ($CHAIN)"
print_header "$SUITE_TITLE"
echo "${C_DIM}wallet: $WALLET   amount: $AMOUNT OMNI${C_RESET}"

# Snapshot pre
resp=$(rpc "getbalance" "[\"$WALLET\"]")
assert_ok "$resp" "pre-balance" >/dev/null
BAL_PRE=$(json_get "$resp" ".result")
print_info "balance pre  : $BAL_PRE"

resp=$(rpc "getstake" "[\"$WALLET\"]")
STAKE_PRE=$(json_get "$resp" ".result.amount")
STAKE_PRE=${STAKE_PRE:-0}
print_info "stake pre    : $STAKE_PRE"

# Submit stake
echo
echo "${C_DIM}-- submitting stake --${C_RESET}"
resp=$(rpc "stake" "[{\"address\":\"$WALLET\",\"amount\":$AMOUNT}]")
assert_ok "$resp" "stake submit"

# Wait
sleep 10

# Snapshot post-stake
resp=$(rpc "getbalance" "[\"$WALLET\"]")
BAL_MID=$(json_get "$resp" ".result")
print_info "balance mid  : $BAL_MID"

resp=$(rpc "getstake" "[\"$WALLET\"]")
STAKE_MID=$(json_get "$resp" ".result.amount")
STAKE_MID=${STAKE_MID:-0}
print_info "stake mid    : $STAKE_MID"

# Validate stake delta
delta_bal=$(awk "BEGIN{print $BAL_PRE - $BAL_MID}")
delta_stake=$(awk "BEGIN{print $STAKE_MID - $STAKE_PRE}")
if awk "BEGIN{exit !($delta_bal >= $AMOUNT - 0.5 && $delta_bal <= $AMOUNT + 0.5)}"; then
    print_pass "balance decreased by ~$AMOUNT (got $delta_bal)"
else
    print_fail "balance delta wrong" "expected ~$AMOUNT, got $delta_bal"
fi
if awk "BEGIN{exit !($delta_stake >= $AMOUNT - 0.001)}"; then
    print_pass "getstake increased by ~$AMOUNT"
else
    print_fail "getstake delta wrong" "expected +$AMOUNT, got +$delta_stake"
fi

# Unstake
echo
echo "${C_DIM}-- submitting unstake --${C_RESET}"
resp=$(rpc "unstake" "[{\"address\":\"$WALLET\",\"amount\":$AMOUNT}]")
assert_ok "$resp" "unstake submit"
sleep 10

# Snapshot post-unstake
resp=$(rpc "getbalance" "[\"$WALLET\"]")
BAL_POST=$(json_get "$resp" ".result")
print_info "balance post : $BAL_POST"

resp=$(rpc "getstake" "[\"$WALLET\"]")
STAKE_POST=$(json_get "$resp" ".result.amount")
STAKE_POST=${STAKE_POST:-0}
print_info "stake post   : $STAKE_POST"

# Validate restoration
delta_bal_full=$(awk "BEGIN{print $BAL_PRE - $BAL_POST}")
if awk "BEGIN{exit !($delta_bal_full <= 0.5 && $delta_bal_full >= -0.5)}"; then
    print_pass "balance restored to pre-test value (~0 net delta)"
else
    print_fail "balance NOT restored" "net delta=$delta_bal_full (BUG: stake balance lock)"
fi
if awk "BEGIN{exit !($STAKE_POST <= $STAKE_PRE + 0.001)}"; then
    print_pass "getstake returned to original"
else
    print_fail "stake leaked" "post=$STAKE_POST pre=$STAKE_PRE"
fi

finish
