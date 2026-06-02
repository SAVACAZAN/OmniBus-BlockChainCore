#!/usr/bin/env bash
# 01-chain-basic.sh — Basic chain RPC: count, balance, richlist, block, perf, sync, peers, mempool
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="01 Chain Basic"
print_header "$SUITE_TITLE"

# 1) getblockcount
resp=$(rpc "getblockcount" "[]")
assert_ok "$resp" "getblockcount"
height=$(json_get "$resp" ".result")
[ -n "$height" ] && [ "$height" != "null" ] && print_info "block height: $height"

# 2) getbalance (treasury wallet from CLAUDE.md memory)
resp=$(rpc "getbalance" '["ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"]')
assert_ok "$resp" "getbalance (savacazan #0)"
bal=$(json_get "$resp" ".result")
[ -n "$bal" ] && print_info "balance: $bal"

# 3) getrichlist [3]
resp=$(rpc "getrichlist" "[3]")
assert_ok "$resp" "getrichlist [3]"
assert_has_field "$resp" "address" "getrichlist contains address field"

# 4) getblock latest (use height from step 1; fallback to "latest")
if [ -n "$height" ] && [ "$height" != "null" ]; then
    resp=$(rpc "getblock" "[\"$height\"]")
    assert_ok "$resp" "getblock latest (#$height)"
    assert_has_field "$resp" "hash" "getblock has hash"
else
    resp=$(rpc "getblock" '["latest"]')
    assert_ok "$resp" "getblock latest"
fi

# 5) getperformance
resp=$(rpc "getperformance" "[]")
assert_ok "$resp" "getperformance"

# 6) getsyncstatus
resp=$(rpc "getsyncstatus" "[]")
assert_ok "$resp" "getsyncstatus"

# 7) getpeers
resp=$(rpc "getpeers" "[]")
assert_ok "$resp" "getpeers"

# 8) getmempoolinfo
resp=$(rpc "getmempoolinfo" "[]")
assert_ok "$resp" "getmempoolinfo"

finish
