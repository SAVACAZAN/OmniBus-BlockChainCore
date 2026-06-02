#!/usr/bin/env bash
# 16-pq-attest.sh — Cross-chain PQ identity (pq_attest_v1) read-only smoke.
#
# Validates that the pq_attest 7-key identity flow (OMNI ECDSA + 4 PQ
# soulbound + BTC + ETH) is queryable on the running node:
#   - getpqidentity {address}     — does an attest exist?
#   - pq_listSchemes               — schemes available (Falcon/MLDSA/SLHDSA/MLKEM)
#   - pq_balance {address}         — soulbound cup balances per PQ domain
#   - pq_verify_test               — batch sig verify (canary)
#   - sendpqattest                 — read-only verify path (NO --write)
#
# Read-only by design: never broadcasts. Uses the savacazan registrar
# slot as the canary address (slot #0, deterministic forever).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="16 PQ Attest (cross-chain identity)"
print_header "$SUITE_TITLE"

# Canary address: registrar slot #0 (savacazan), present on every chain.
ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"

# 1) getpqidentity — attest record (may be empty on testnet/regtest)
resp=$(rpc "getpqidentity" "[\"$ADDR\"]")
assert_ok "$resp" "getpqidentity (savacazan #0)"
rc=$?
if [ "$rc" = "0" ]; then
    # Optional shape probe: love/food/rent/vacation cups, btc/eth refs,
    # plus attest_block / attest_tx where it landed.
    for f in love food rent vacation attest_block attest_tx; do
        if echo "$resp" | grep -q "\"$f\""; then
            print_pass "  field present: $f"
        else
            print_skip "  field present: $f" "may be unattested"
        fi
    done
    # btc/eth optional anchors
    for f in btc eth; do
        if echo "$resp" | grep -q "\"$f\""; then
            print_pass "  optional anchor: $f"
        else
            print_skip "  optional anchor: $f" "not yet linked"
        fi
    done
fi

# 2) pq_listSchemes — registered PQ algorithms
resp=$(rpc "pq_listSchemes" "[]")
assert_ok "$resp" "pq_listSchemes"
rc=$?
if [ "$rc" = "0" ]; then
    # Expect ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768 prefixes
    # (raw or labelled). Match prefixes ob_k1_/ob_f5_/ob_d5_/ob_s3_.
    for prefix in "ob_k1_" "ob_f5_" "ob_d5_" "ob_s3_"; do
        if echo "$resp" | grep -q "$prefix"; then
            print_pass "  scheme prefix: $prefix"
        else
            print_skip "  scheme prefix: $prefix" "not surfaced in list"
        fi
    done
fi

# 3) pq_balance — soulbound cups per PQ domain (LOVE/FOOD/RENT/VACATION)
resp=$(rpc "pq_balance" "[\"$ADDR\"]")
assert_ok "$resp" "pq_balance (savacazan #0)"
rc=$?
if [ "$rc" = "0" ]; then
    for f in love food rent vacation; do
        if echo "$resp" | grep -q "\"$f\""; then
            print_pass "  pq cup: $f"
        else
            print_skip "  pq cup: $f" "may be zero or omitted"
        fi
    done
fi

# 4) pq_verify_test — canary batch verify (synthetic message)
#    We pass an empty message + empty sigs array; node returns
#    {ok:false, reason:"empty"} or similar. We only assert the RPC
#    is callable (not the truth-value).
resp=$(rpc "pq_verify_test" '[{"message":"00","signatures":[]}]')
assert_ok "$resp" "pq_verify_test (empty canary)"

# 5) sendpqattest — read-only verify path. Build a no-op payload so
#    the node validates structure but never broadcasts. NO --write.
resp=$(rpc "sendpqattest" '[{"address":"'"$ADDR"'","signatures":[],"dry_run":true}]')
# Either method-not-found (older nodes), validation error, or ok.
err=$(json_get "$resp" ".error.message")
if [ -z "$err" ] || [ "$err" = "null" ]; then
    print_pass "sendpqattest dry_run accepted"
elif echo "$err" | grep -qiE "method not found|unknown method|not implemented"; then
    print_skip "sendpqattest dry_run" "method not found"
elif echo "$err" | grep -qiE "missing|invalid|empty|signatures|dry"; then
    # Validation error is the *correct* behaviour for an empty payload.
    print_pass "sendpqattest dry_run rejected (expected: empty sigs)"
else
    print_fail "sendpqattest dry_run" "unexpected error: $err"
fi

finish
