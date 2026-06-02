#!/usr/bin/env bash
# 12-governance.sh — DAO proposals (read-only)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="12 Governance"
print_header "$SUITE_TITLE"

# 1) getproposals
resp=$(rpc "getproposals" "[]")
assert_ok "$resp" "getproposals"

# 2) getproposal id=0
resp=$(rpc "getproposal" '[{"id":0}]')
err=$(json_get "$resp" ".error.message")
if [ -n "$err" ] && echo "$err" | grep -qiE "not found|invalid id|no proposal"; then
    # acceptable: no proposal #0 yet
    print_pass "getproposal id=0 (no proposal exists — clean reply)"
else
    assert_ok "$resp" "getproposal id=0"
fi

finish
