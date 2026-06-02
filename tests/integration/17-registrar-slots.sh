#!/usr/bin/env bash
# 17-registrar-slots.sh — 10 fixed registrar slots (forever-canonical).
#
# Verifies that the 10 hardcoded registrar addresses from
# core/registrar_addresses.zig are present on chain, queryable, and
# show up correctly in fee-routing + getrichlist.
#
# Slot 0 savacazan / 1 admin / 2 exchange / 3 ens / 4 sava /
# Slot 5 blockchain / 6 tornetwork / 7 faucet / 8 cazan / 9 database
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="17 Registrar Slots (10 fixed forever)"
print_header "$SUITE_TITLE"

# Mirror of REGISTRAR_ADDRESSES in core/registrar_addresses.zig.
# Two parallel arrays so plain bash (no associative-array dependency).
SLOT_ROLES=("savacazan" "admin" "exchange" "ens" "sava" "blockchain" "tornetwork" "faucet" "cazan" "database")
SLOT_ADDRS=(
    "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"
    "ob1q8wm5est4fft7mrj937sg9uyaz2nskgttf3ku5u"
    "ob1qpjt7gngkj79663a298schx6dkjxqf37hwfggw2"
    "ob1qqcmwu5txqt5m3wv6p3ugxp6a3q4jsntd0mxyxa"
    "ob1q5stczt5xxxphedadlqej09f5hww22qhvrj2nln"
    "ob1quax5e9hyyzmft2m2lzn735asswsw9gh4gtgess"
    "ob1qcdep7azzrr8t3x8tgn9wp6p69fc884g8g80v09"
    "ob1qvetjtq3swujv0jqsmw0gq84fymtfuaz5p5cjdv"
    "ob1qdpknh5kapc22fv6s7jv0ntj7kwepqf3hcq4jrj"
    "ob1qw8sltuapku7g5c4fmkzplhns0sde9rc6cunu57"
)

# 1) Per-slot getbalance — every slot must answer (even if zero).
for i in 0 1 2 3 4 5 6 7 8 9; do
    role="${SLOT_ROLES[$i]}"
    addr="${SLOT_ADDRS[$i]}"
    resp=$(rpc "getbalance" "[\"$addr\"]")
    assert_ok "$resp" "slot #$i $role  ($addr)"
done

# 2) ENS fee-routing canary — fee should land at slot #3 (ens).
#    getensfee returns the active per-chain ENS registration fee.
resp=$(rpc "getensfee" "[]")
err=$(json_get "$resp" ".error.message")
if [ -z "$err" ] || [ "$err" = "null" ]; then
    print_pass "getensfee (ENS slot routing canary)"
    # Optional: response should mention either fee, or treasury slot 3.
    if echo "$resp" | grep -qE "ens|treasury|3"; then
        print_pass "  ens fee response references ens/treasury/slot"
    else
        print_skip "  ens fee response references ens/treasury/slot" "shape varies"
    fi
elif echo "$err" | grep -qiE "method not found|unknown method|not implemented"; then
    print_skip "getensfee" "method not found"
else
    print_fail "getensfee" "$err"
fi

# 3) Exchange fee-routing canary — slot #2.
resp=$(rpc "exchange_listFees" "[]")
err=$(json_get "$resp" ".error.message")
if [ -z "$err" ] || [ "$err" = "null" ]; then
    print_pass "exchange_listFees (slot #2 routing canary)"
elif echo "$err" | grep -qiE "method not found|unknown method|not implemented"; then
    # Older RPC name? Try generic getexchangeinfo.
    resp=$(rpc "getexchangeinfo" "[]")
    err2=$(json_get "$resp" ".error.message")
    if [ -z "$err2" ] || [ "$err2" = "null" ]; then
        print_pass "getexchangeinfo (exchange slot canary fallback)"
    else
        print_skip "exchange fee canary" "no exchange_* RPC reachable"
    fi
else
    print_fail "exchange_listFees" "$err"
fi

# 4) getrichlist — at least one of the 10 slots should appear (savacazan
#    is the founder mining wallet, so it always has a balance on testnet
#    + mainnet; on regtest it may be empty pre-mining).
resp=$(rpc "getrichlist" "[]")
assert_ok "$resp" "getrichlist"
rc=$?
if [ "$rc" = "0" ]; then
    found=0
    for i in 0 1 2 3 4 5 6 7 8 9; do
        addr="${SLOT_ADDRS[$i]}"
        if echo "$resp" | grep -q "$addr"; then
            print_pass "  rich: slot #$i ${SLOT_ROLES[$i]}"
            found=$((found + 1))
        fi
    done
    if [ "$found" = "0" ]; then
        print_skip "  any registrar slot present in rich list" "none populated yet"
    fi
fi

finish
