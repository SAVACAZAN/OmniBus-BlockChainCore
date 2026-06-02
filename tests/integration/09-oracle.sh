#!/usr/bin/env bash
# 09-oracle.sh — Price oracle, exchange feed, arbitrage, foreign-chain heights
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="09 Oracle & Price Feeds"
print_header "$SUITE_TITLE"

# 1) omnibus_getexchangefeed
resp=$(rpc "omnibus_getexchangefeed" "[]")
assert_ok "$resp" "omnibus_getexchangefeed"

# 2) omnibus_getallprices [0,5]
resp=$(rpc "omnibus_getallprices" "[0,5]")
assert_ok "$resp" "omnibus_getallprices [0,5]"

# 3) omnibus_getarbitrage
resp=$(rpc "omnibus_getarbitrage" "[]")
assert_ok "$resp" "omnibus_getarbitrage"

# 4) omnibus_getoracleprices
resp=$(rpc "omnibus_getoracleprices" "[]")
assert_ok "$resp" "omnibus_getoracleprices"

# 5) omnibus_getoraclepolicy
resp=$(rpc "omnibus_getoraclepolicy" "[]")
assert_ok "$resp" "omnibus_getoraclepolicy"

# 6) oracle_btcHeight
resp=$(rpc "oracle_btcHeight" "[]")
assert_ok "$resp" "oracle_btcHeight"

# 7) oracle_ethHeight
resp=$(rpc "oracle_ethHeight" "[]")
assert_ok "$resp" "oracle_ethHeight"

finish
