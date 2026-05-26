#!/usr/bin/env bash
# _vps-health.sh — VPS health check across all 5 OmniBus services
# Exits 0 if everything healthy, 1 if any problem detected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"

VPS_HOST="${VPS_HOST:-omnibus-vps}"
# Detect if running directly on the VPS — skip SSH wrapping in that case.
# Hostname check is the simplest and most portable.
if [ "$(hostname 2>/dev/null)" = "vm2111" ] || [ -d /root/omnibus-blockchain ]; then
    SSH_RUN=""  # run commands locally
else
    SSH_RUN="ssh -o ConnectTimeout=8 -o BatchMode=yes $VPS_HOST"
fi
run_remote() {
    if [ -z "$SSH_RUN" ]; then bash -c "$1"; else $SSH_RUN "$1"; fi
}
SERVICES=(omnibus-mainnet omnibus-mainnet-miner omnibus-testnet omnibus-regtest omnibus-oracle)
PROBLEMS=0
SUITE_TITLE="VPS Health Check"
print_header "$SUITE_TITLE"

echo "${C_DIM}target host: $VPS_HOST${C_RESET}"

# 1) systemd service status
echo
echo "${C_BLUE}-- systemd services --${C_RESET}"
for svc in "${SERVICES[@]}"; do
    state=$(run_remote "systemctl is-active $svc" 2>/dev/null || echo "unreachable")
    case "$state" in
        active)        echo "  ${C_GREEN}OK${C_RESET}    $svc" ;;
        inactive|failed|unreachable)
                       echo "  ${C_RED}FAIL${C_RESET}  $svc ($state)"
                       PROBLEMS=$((PROBLEMS+1)) ;;
        *)             echo "  ${C_YELLOW}WARN${C_RESET}  $svc ($state)"
                       PROBLEMS=$((PROBLEMS+1)) ;;
    esac
done

# 2) memory + load
echo
echo "${C_BLUE}-- memory + load --${C_RESET}"
mem_line=$(run_remote "free -m | awk 'NR==2{printf \"used=%dMB total=%dMB pct=%.0f%%\", \$3, \$2, \$3*100/\$2}'" 2>/dev/null || echo "ssh-error")
echo "  mem:  $mem_line"
mem_pct=$(echo "$mem_line" | sed -n 's/.*pct=\([0-9]\+\)%.*/\1/p')
if [ -n "$mem_pct" ] && [ "$mem_pct" -gt 90 ]; then
    echo "  ${C_RED}WARN${C_RESET} memory >90%"
    PROBLEMS=$((PROBLEMS+1))
fi

uptime_line=$(run_remote "uptime" 2>/dev/null || echo "ssh-error")
echo "  load: $uptime_line"

# 3) disk
echo
echo "${C_BLUE}-- disk --${C_RESET}"
disk_line=$(run_remote "df -h / | awk 'NR==2{print \$3 \" used / \" \$2 \" total — \" \$5 \" full\"}'" 2>/dev/null || echo "ssh-error")
echo "  /:    $disk_line"
disk_pct=$(echo "$disk_line" | sed -n 's/.*\([0-9]\+\)% full.*/\1/p')
if [ -n "$disk_pct" ] && [ "$disk_pct" -gt 85 ]; then
    echo "  ${C_RED}WARN${C_RESET} disk >85%"
    PROBLEMS=$((PROBLEMS+1))
fi

# 4) chain heights
echo
echo "${C_BLUE}-- chain heights --${C_RESET}"
for chain in mainnet testnet regtest; do
    resp=$(CHAIN="$chain" rpc "getblockcount" "[]" 2>/dev/null || echo '{"error":{"message":"unreachable"}}')
    err=$(json_get "$resp" ".error.message")
    if [ -n "$err" ] && [ "$err" != "null" ]; then
        echo "  ${C_RED}FAIL${C_RESET} $chain getblockcount: $err"
        PROBLEMS=$((PROBLEMS+1))
    else
        h=$(json_get "$resp" ".result")
        echo "  ${C_GREEN}OK${C_RESET}    $chain height=$h"
    fi
done

# 5) panic count last 24h
echo
echo "${C_BLUE}-- panic count (last 24h) --${C_RESET}"
panic_total=0
for log in mainnet testnet regtest; do
    n=$(run_remote "find /var/log/omnibus/${log}.log -mtime -1 2>/dev/null | xargs grep -c -i panic 2>/dev/null || echo 0" 2>/dev/null || echo 0)
    n=${n:-0}
    panic_total=$((panic_total + n))
    if [ "$n" -gt 0 ]; then
        echo "  ${C_YELLOW}WARN${C_RESET}  $log.log: $n panic(s)"
    else
        echo "  ${C_GREEN}OK${C_RESET}    $log.log: 0"
    fi
done
if [ "$panic_total" -gt 5 ]; then
    PROBLEMS=$((PROBLEMS+1))
fi

# 6) top processes
echo
echo "${C_BLUE}-- top omnibus processes (cpu/mem) --${C_RESET}"
run_remote "ps -eo pid,pcpu,pmem,comm --sort=-pcpu | grep -E 'omnibus|zig' | head -8" 2>/dev/null \
    | awk '{printf "  %-7s cpu=%-5s mem=%-5s %s\n", $1, $2, $3, $4}' \
    || echo "  ${C_DIM}ssh failed${C_RESET}"

# Summary
echo
if [ "$PROBLEMS" -eq 0 ]; then
    echo "${C_GREEN}=== ALL HEALTHY ===${C_RESET}"
    exit 0
else
    echo "${C_RED}=== $PROBLEMS problem(s) detected ===${C_RESET}"
    exit 1
fi
