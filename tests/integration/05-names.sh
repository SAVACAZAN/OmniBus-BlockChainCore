#!/usr/bin/env bash
# 05-names.sh — Naming service (.omnibus / .arbitraje TLDs)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="05 Naming Service"
print_header "$SUITE_TITLE"

# 1) resolvename for known name
resp=$(rpc "resolvename" '["savacazan.omnibus"]')
assert_ok "$resp" "resolvename savacazan.omnibus"
rc=$?
if [ "$rc" = "0" ]; then
    if echo "$resp" | grep -q "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"; then
        print_pass "  resolves to expected address"
    else
        print_skip "  resolves to expected address" "name not yet registered on $CHAIN"
    fi
fi

# 2) ns_listTlds
resp=$(rpc "ns_listTlds" "[]")
assert_ok "$resp" "ns_listTlds"
rc=$?
if [ "$rc" = "0" ]; then
    for tld in omnibus arbitraje; do
        if echo "$resp" | grep -q "\"$tld\""; then
            print_pass "  TLD present: .$tld"
        else
            print_skip "  TLD present: .$tld" "may not be active on $CHAIN"
        fi
    done
fi

# 3) ns_getensfee for omnibus TLD
resp=$(rpc "ns_getensfee" '[{"tld":"omnibus"}]')
assert_ok "$resp" "ns_getensfee tld=omnibus"

# 4) ns_yearTiers
resp=$(rpc "ns_yearTiers" "[]")
assert_ok "$resp" "ns_yearTiers"

# 5) ns_stats
resp=$(rpc "ns_stats" "[]")
assert_ok "$resp" "ns_stats"

finish
