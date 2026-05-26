#!/usr/bin/env bash
# 10-notarize-sub.sh — Document notarization + subscriptions
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="10 Notarize & Subscriptions"
print_header "$SUITE_TITLE"

ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"
# Synthetic 64-hex doc hash (deterministic, all zeros — should return "not found" cleanly)
DOC_HASH="0000000000000000000000000000000000000000000000000000000000000000"

# 1) getnotarizations for known address
resp=$(rpc "getnotarizations" "[{\"address\":\"$ADDR\"}]")
assert_ok "$resp" "getnotarizations savacazan"

# 2) verifynotarize with synthetic hash — should be ok with empty/found:false, not crash
resp=$(rpc "verifynotarize" "[{\"doc_hash\":\"$DOC_HASH\"}]")
err=$(json_get "$resp" ".error.message")
if [ -n "$err" ] && echo "$err" | grep -qiE "not found|invalid hash"; then
    # acceptable: chain replied cleanly that the hash isn't notarized
    print_pass "verifynotarize (zero hash → not_found cleanly)"
else
    assert_ok "$resp" "verifynotarize zero-hash"
fi

# 3) getsubscriptions for known address
resp=$(rpc "getsubscriptions" "[{\"address\":\"$ADDR\"}]")
assert_ok "$resp" "getsubscriptions savacazan"

finish
