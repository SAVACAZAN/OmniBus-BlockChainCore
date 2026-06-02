#!/usr/bin/env bash
# E2E smoke test for V3 wire format (miner_id propagation through sync).
#
# Prereq: Both PC and VPS run a V3 binary (zig build -Doqs=false fresh).
# This script:
#   1. Queries PC node RPC at port 18333 (testnet, miner mode)
#   2. Queries VPS node RPC at https://omnibusblockchain.cc:8443/rpc
#   3. For each: samples 5 recent blocks and counts unique miners
#   4. Asserts both PC and VPS see >= 2 distinct non-empty miner addresses
#
# Exit 0 = pass (V3 works), exit 1 = fail.
set -euo pipefail

PC_RPC="http://127.0.0.1:18333"
VPS_RPC="https://omnibusblockchain.cc:8443/rpc"
VPS_TOKEN="${OMNIBUS_VPS_TOKEN:-}"   # bearer token for VPS auth

# Use jq if available, fallback to grep
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

rpc() {
  local url="$1" method="$2" params="$3"
  local extra=()
  if [[ "$url" == *"omnibusblockchain.cc"* && -n "$VPS_TOKEN" ]]; then
    extra=(-H "Authorization: Bearer $VPS_TOKEN")
  fi
  curl -sS -m 10 -X POST "${extra[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
    "$url"
}

extract_miner() {
  if [[ $have_jq -eq 1 ]]; then
    jq -r '.result.miner // ""'
  else
    grep -oE '"miner":"[^"]*"' | sed 's/"miner":"\(.*\)"/\1/'
  fi
}

extract_height() {
  if [[ $have_jq -eq 1 ]]; then
    jq -r '.result.blocks // .result.height // 0'
  else
    grep -oE '"blocks":[0-9]+' | head -1 | grep -oE '[0-9]+'
  fi
}

probe_node() {
  local label="$1" url="$2"
  echo "=== $label ($url) ==="
  local info; info=$(rpc "$url" getblockchaininfo "[]" || echo '{}')
  local h; h=$(echo "$info" | extract_height)
  if [[ -z "$h" || "$h" == "0" ]]; then
    echo "  FAIL: cannot reach $label or height=0"
    return 1
  fi
  echo "  height: $h"

  declare -A miners=()
  local sampled=0
  for off in 0 5 10 20 40; do
    local query_h=$((h - off))
    [[ $query_h -lt 1 ]] && continue
    local blk; blk=$(rpc "$url" getblock "[$query_h]" 2>/dev/null || echo '{}')
    local m; m=$(echo "$blk" | extract_miner)
    if [[ -n "$m" && "$m" != "null" ]]; then
      miners["$m"]=1
      echo "  block $query_h → miner=$m"
      sampled=$((sampled+1))
    else
      echo "  block $query_h → miner=<empty>"
    fi
  done

  local unique=${#miners[@]}
  echo "  unique non-empty miners across samples: $unique"
  if [[ $unique -ge 2 ]]; then
    echo "  PASS: $label sees multiple miners"
    return 0
  elif [[ $unique -eq 1 ]]; then
    echo "  WARN: $label sees only 1 miner (V2 chain residue, or genuinely 1 active)"
    return 2
  else
    echo "  FAIL: $label sees 0 miners"
    return 1
  fi
}

result=0
probe_node "PC node" "$PC_RPC" || result=$?
echo
probe_node "VPS node" "$VPS_RPC" || result=$?

echo
case $result in
  0) echo "RESULT: ALL PASS — V3 working, both nodes see multiple miners";;
  2) echo "RESULT: PARTIAL — node up but only 1 miner sampled (chain may be V2-era; need fresh height after V3 deploy)";;
  *) echo "RESULT: FAIL — see logs above";;
esac
exit $result
