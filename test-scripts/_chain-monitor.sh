#!/usr/bin/env bash
# _chain-monitor.sh — Continuous chain dashboard (refresh every INTERVAL seconds).
# Logs to chain-monitor-<unix>.log. Ctrl+C for graceful stop.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"

INTERVAL="${INTERVAL:-30}"
VPS_HOST="${VPS_HOST:-omnibus-vps}"
LOG_FILE="chain-monitor-$(date +%s).log"
ITER=0
PREV_HEIGHT=""
PREV_TS=""
CRASH_TOTAL=0

trap 'echo; echo "${C_BLUE}=== monitor stopped after $ITER iters — log: $LOG_FILE ===${C_RESET}"; exit 0' INT TERM

print_header "Chain Monitor — every ${INTERVAL}s"
echo "${C_DIM}log file: $LOG_FILE${C_RESET}"
echo "${C_DIM}press Ctrl+C to stop${C_RESET}"

color_for_load() {
    local L=$1
    awk "BEGIN{
        if ($L < 1.5) print \"$C_GREEN\";
        else if ($L < 4.0) print \"$C_YELLOW\";
        else print \"$C_RED\";
    }"
}

while true; do
    ITER=$((ITER+1))
    NOW_TS=$(date +%s)
    NOW_ISO=$(date -Iseconds 2>/dev/null || date)
    line_buf=""

    # Block heights (3 chains)
    declare -A HEIGHT
    for chain in mainnet testnet regtest; do
        resp=$(CHAIN="$chain" rpc "getblockcount" "[]" 2>/dev/null || echo '{}')
        HEIGHT[$chain]=$(json_get "$resp" ".result")
        HEIGHT[$chain]=${HEIGHT[$chain]:-?}
    done

    # Block rate (mainnet)
    bps_str="--"
    if [ -n "$PREV_HEIGHT" ] && [ "${HEIGHT[mainnet]}" != "?" ] && [ "$PREV_HEIGHT" != "?" ]; then
        dh=$((${HEIGHT[mainnet]} - PREV_HEIGHT))
        dt=$((NOW_TS - PREV_TS))
        if [ "$dt" -gt 0 ]; then
            bps_str=$(awk "BEGIN{printf \"%.2f blk/min\", ($dh/$dt)*60}")
        fi
    fi
    PREV_HEIGHT="${HEIGHT[mainnet]}"
    PREV_TS=$NOW_TS

    # Latest block tx count + mempool
    resp=$(CHAIN=mainnet rpc "getblock" "[\"${HEIGHT[mainnet]}\"]" 2>/dev/null || echo '{}')
    txn=$(echo "$resp" | grep -oE '"tx"\s*:\s*\[[^]]*\]' | grep -oE '"[a-f0-9]{8,}"' | wc -l | tr -d ' ')
    [ -z "$txn" ] || [ "$txn" = "0" ] && txn=$(json_get "$resp" ".result.tx_count")
    txn=${txn:-?}

    resp=$(CHAIN=mainnet rpc "getmempoolinfo" "[]" 2>/dev/null || echo '{}')
    mp=$(json_get "$resp" ".result.size")
    mp=${mp:-?}

    # Oracle prices
    resp=$(CHAIN=mainnet rpc "oracle_getPrices" "[]" 2>/dev/null || echo '{}')
    btc=$(echo "$resp" | sed -n 's/.*"BTC":\([0-9.]*\).*/\1/p' | head -1)
    lcx=$(echo "$resp" | sed -n 's/.*"LCX":\([0-9.]*\).*/\1/p' | head -1)
    btc=${btc:-?}; lcx=${lcx:-?}

    # Active stakers / validators
    resp=$(CHAIN=mainnet rpc "getstakers" "[]" 2>/dev/null || echo '{}')
    stakers=$(echo "$resp" | grep -oE '"address"' | wc -l | tr -d ' ')
    resp=$(CHAIN=mainnet rpc "getvalidatorsv2" "[]" 2>/dev/null || echo '{}')
    validators=$(echo "$resp" | grep -oE '"address"' | wc -l | tr -d ' ')

    # VPS load
    load=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$VPS_HOST" "uptime | awk -F'load average: ' '{print \$2}' | awk -F, '{print \$1}'" 2>/dev/null || echo "?")
    load_color=$(color_for_load "${load:-99}")

    # Crash count delta
    crashes=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$VPS_HOST" "grep -c -i panic /var/log/omnibus/mainnet.log 2>/dev/null || echo 0" 2>/dev/null || echo 0)
    crashes=${crashes:-0}
    if [ "$crashes" != "$CRASH_TOTAL" ] && [ "$ITER" -gt 1 ]; then
        crash_str="${C_RED}!!! crashes: $crashes (was $CRASH_TOTAL)${C_RESET}"
    else
        crash_str="${C_GREEN}crashes: $crashes${C_RESET}"
    fi
    CRASH_TOTAL="$crashes"

    # Status color
    health="${C_GREEN}healthy${C_RESET}"
    if [ "${HEIGHT[mainnet]}" = "?" ] || [ "${HEIGHT[testnet]}" = "?" ]; then
        health="${C_RED}critical${C_RESET}"
    elif awk "BEGIN{exit !(${load:-0}+0 > 4)}" 2>/dev/null; then
        health="${C_YELLOW}warn-load${C_RESET}"
    fi

    # Render
    {
    echo
    echo "${C_BLUE}── iter #$ITER  $NOW_ISO  [$health] ──${C_RESET}"
    printf "  height : main=%-8s test=%-8s reg=%-8s  rate=%s\n" "${HEIGHT[mainnet]}" "${HEIGHT[testnet]}" "${HEIGHT[regtest]}" "$bps_str"
    printf "  block  : tx=%s   mempool=%s\n" "$txn" "$mp"
    printf "  oracle : BTC=%s   LCX=%s\n" "$btc" "$lcx"
    printf "  consen : stakers=%s   validators=%s\n" "$stakers" "$validators"
    printf "  vps    : load=${load_color}%s${C_RESET}   %s\n" "$load" "$crash_str"
    } | tee -a "$LOG_FILE"

    sleep "$INTERVAL"
done
