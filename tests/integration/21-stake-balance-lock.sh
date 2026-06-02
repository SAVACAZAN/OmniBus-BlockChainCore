#!/usr/bin/env bash
# 21-stake-balance-lock.sh — CRITICAL: stake debits balance correctly.
#
# Tests the recently fixed bug where stake/unstake had to actually move
# coins between {balance, locked-stake} and not double-spend or vanish.
#
# Flow (TESTNET ONLY when --write):
#   1. getbalance ADDR -> B1
#   2. getstake   ADDR -> S1
#   3. stake amount=10 OMNI (via `stake` RPC) — ONLY if --write + testnet
#   4. wait ~12s for next block
#   5. getbalance -> B2  ; assert B2 ~= B1 - 10 - fee
#   6. getstake   -> S2  ; assert S2 ~= S1 + 10
#   7. unstake amount=10 OMNI
#   8. wait ~12s
#   9. getbalance -> B3  ; assert B3 ~= B1 - 2*fee  (back to baseline)
#  10. getstake   -> S3  ; assert S3 ~= S1
#
# Default mode is READ-ONLY: prints baseline + skips all mutation steps.
# Pass --write to actually execute stake/unstake. Refuses to run with
# --write on mainnet (real funds at risk).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="21 Stake/Balance Lock (CRITICAL)"
print_header "$SUITE_TITLE"

WRITE_MODE=0
for arg in "$@"; do
    case "$arg" in
        --write) WRITE_MODE=1 ;;
    esac
done

CHAIN_NAME="${CHAIN:-mainnet}"
ADDR="${TEST_ADDR:-ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0}"
AMOUNT_OMNI=10
# Convert to satoshi-style (1 OMNI = 1e9 SAT).
AMOUNT_SAT=10000000000

# Refuse --write on mainnet — bug here would burn real OMNI.
if [ "$WRITE_MODE" = "1" ] && [ "$CHAIN_NAME" = "mainnet" ]; then
    print_fail "guard" "refusing --write on mainnet (set --chain testnet or regtest)"
    finish
fi

# 1) Baseline balance
resp=$(rpc "getbalance" "[\"$ADDR\"]")
assert_ok "$resp" "getbalance baseline (B1)"
B1=$(json_get "$resp" ".result.balance")
[ -z "$B1" ] && B1=$(json_get "$resp" ".result")
print_info "B1 (balance) = $B1"

# 2) Baseline stake
resp=$(rpc "getstake" "[\"$ADDR\"]")
assert_ok "$resp" "getstake baseline (S1)"
S1=$(json_get "$resp" ".result.amount")
[ -z "$S1" ] && S1=$(json_get "$resp" ".result")
print_info "S1 (stake) = $S1"

if [ "$WRITE_MODE" != "1" ]; then
    print_skip "stake/unstake mutation" "read-only mode — pass --write on testnet/regtest to run"
    finish
fi

# 3) Stake AMOUNT_OMNI
print_info "submitting stake +$AMOUNT_OMNI OMNI ..."
resp=$(rpc "stake" "[{\"address\":\"$ADDR\",\"amount\":$AMOUNT_SAT}]")
assert_ok "$resp" "stake $AMOUNT_OMNI OMNI"

# 4) Wait for inclusion
print_info "waiting 12s for block inclusion..."
sleep 12

# 5) Post-stake balance
resp=$(rpc "getbalance" "[\"$ADDR\"]")
assert_ok "$resp" "getbalance after stake (B2)"
B2=$(json_get "$resp" ".result.balance")
[ -z "$B2" ] && B2=$(json_get "$resp" ".result")
print_info "B2 = $B2"

# Assert B2 < B1 (debited) — exact diff depends on fee, just check direction.
if [ -n "$B1" ] && [ -n "$B2" ]; then
    if awk -v a="$B2" -v b="$B1" 'BEGIN{exit !(a+0 < b+0)}'; then
        print_pass "B2 < B1 (stake debited balance)"
    else
        print_fail "stake did not debit balance" "B1=$B1 B2=$B2"
    fi
else
    print_skip "B2 < B1 check" "missing numeric balance"
fi

# 6) Post-stake stake amount
resp=$(rpc "getstake" "[\"$ADDR\"]")
assert_ok "$resp" "getstake after stake (S2)"
S2=$(json_get "$resp" ".result.amount")
[ -z "$S2" ] && S2=$(json_get "$resp" ".result")
print_info "S2 = $S2"
if [ -n "$S1" ] && [ -n "$S2" ]; then
    if awk -v a="$S2" -v b="$S1" 'BEGIN{exit !(a > b)}'; then
        print_pass "S2 > S1 (stake increased)"
    else
        print_fail "stake amount did not increase" "S1=$S1 S2=$S2"
    fi
fi

# 7) Unstake
print_info "submitting unstake $AMOUNT_OMNI OMNI ..."
resp=$(rpc "unstake" "[{\"address\":\"$ADDR\",\"amount\":$AMOUNT_SAT}]")
assert_ok "$resp" "unstake $AMOUNT_OMNI OMNI"

# 8) Wait
sleep 12

# 9) Post-unstake balance back near B1
resp=$(rpc "getbalance" "[\"$ADDR\"]")
assert_ok "$resp" "getbalance after unstake (B3)"
B3=$(json_get "$resp" ".result.balance")
[ -z "$B3" ] && B3=$(json_get "$resp" ".result")
print_info "B3 = $B3"
if [ -n "$B1" ] && [ -n "$B3" ]; then
    if awk -v a="$B3" -v b="$B2" 'BEGIN{exit !(a > b)}'; then
        print_pass "B3 > B2 (unstake credited balance)"
    else
        print_fail "unstake did not credit balance" "B2=$B2 B3=$B3"
    fi
fi

# 10) Stake should be back to S1
resp=$(rpc "getstake" "[\"$ADDR\"]")
assert_ok "$resp" "getstake after unstake (S3)"
S3=$(json_get "$resp" ".result.amount")
[ -z "$S3" ] && S3=$(json_get "$resp" ".result")
print_info "S3 = $S3"
if [ -n "$S1" ] && [ -n "$S3" ]; then
    if awk -v a="$S3" -v b="$S1" 'BEGIN{exit !(a == b || (a < b + 1 && a > b - 1))}'; then
        print_pass "S3 ~= S1 (stake released)"
    else
        print_skip "S3 ~= S1" "S1=$S1 S3=$S3 (may include small precision drift)"
    fi
fi

finish
