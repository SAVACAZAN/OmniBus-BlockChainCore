#!/usr/bin/env bash
# 02-reputation.sh — Reputation cups (LOVE/FOOD/RENT/VACATION) + leaderboard
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="02 Reputation"
print_header "$SUITE_TITLE"

ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"

# 1) getreputation for known address
resp=$(rpc "getreputation" "[\"$ADDR\"]")
assert_ok "$resp" "getreputation (savacazan #0)"
rc=$?
if [ "$rc" = "0" ]; then
    # check shape: cups{love,food,rent,vacation}, total, tier
    for f in cups love food rent vacation total tier; do
        if echo "$resp" | grep -q "\"$f\""; then
            print_pass "  field present: $f"
        else
            print_fail "  field missing: $f"
        fi
    done
    if echo "$resp" | grep -q "\"satoshi_badge\""; then
        print_pass "  field present: satoshi_badge"
    else
        print_skip "  field present: satoshi_badge" "optional"
    fi
fi

# 2) getreputationtop default
resp=$(rpc "getreputationtop" "[]")
assert_ok "$resp" "getreputationtop default"

# 3) getreputationtop with sort by total
resp=$(rpc "getreputationtop" '[{"sort":"total","limit":10}]')
assert_ok "$resp" "getreputationtop sort=total limit=10"

# 4) getreputationtop with sort by love
resp=$(rpc "getreputationtop" '[{"sort":"love","limit":5}]')
assert_ok "$resp" "getreputationtop sort=love limit=5"

# 5) getreputationtop with sort by tier
resp=$(rpc "getreputationtop" '[{"sort":"tier","limit":5}]')
assert_ok "$resp" "getreputationtop sort=tier limit=5"

finish
