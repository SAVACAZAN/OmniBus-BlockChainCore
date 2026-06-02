#!/usr/bin/env bash
# 11-escrow-channels.sh — Escrow + payment channels
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="11 Escrow & Channels"
print_header "$SUITE_TITLE"

ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"

# 1) getescrows for known address
resp=$(rpc "getescrows" "[{\"address\":\"$ADDR\"}]")
assert_ok "$resp" "getescrows savacazan"

# 2) getchannels for known address
resp=$(rpc "getchannels" "[{\"address\":\"$ADDR\"}]")
assert_ok "$resp" "getchannels savacazan"

finish
