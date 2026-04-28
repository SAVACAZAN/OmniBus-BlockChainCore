#!/usr/bin/env bash
# OmniBus Local Scanner — measures REAL metrics on our regtest node
# Output: results.json
#
# Safe by design: uses --regtest only, never touches mainnet DB.

set -u

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NODE_BIN="$REPO_DIR/zig-out/bin/omnibus-node.exe"
RESULTS_JSON="$SCRIPT_DIR/results.json"
NODE_LOG="$SCRIPT_DIR/bench-node.log"
PID_FILE="$SCRIPT_DIR/bench-node.pid"

# ── Ports ────────────────────────────────────────────────────────────────────
# NOTE: rpc_server.zig has `const PORT = 8332` HARDCODED — chain config rpc_port
# is computed but ignored when the listener actually binds. So the regtest node
# binds RPC on 8332 regardless of --regtest flag. We honor that reality.
# P2P port is configurable via --port, so we use a non-default to avoid
# clashing with anything else on the user's machine.
RPC_PORT=8332
P2P_PORT=29500
RPC_URL="http://127.0.0.1:${RPC_PORT}"

# ── Test parameters ──────────────────────────────────────────────────────────
RPC_SAMPLES=${RPC_SAMPLES:-100}
MINING_WINDOW_SEC=${MINING_WINDOW_SEC:-30}
# IMPORTANT: getmininginfo is placed LAST because it crashes the node on Windows
# regtest builds (segfault inside RPC handler thread — likely race on
# ctx.metrics or blockchain state). Putting it last ensures the other 4 methods
# always complete cleanly. Set SKIP_GETMININGINFO=1 to omit it entirely so the
# node survives long enough for the block-production benchmark below.
RPC_METHODS=(getblockcount getbalance getblockchaininfo getbestblockhash)
if [ "${SKIP_GETMININGINFO:-0}" != "1" ]; then
    RPC_METHODS+=(getmininginfo)
fi

cd "$REPO_DIR" || { echo "[ERROR] Cannot cd to $REPO_DIR"; exit 1; }

echo "================================================================"
echo " OmniBus Local Scanner"
echo " Repo : $REPO_DIR"
echo " Node : $NODE_BIN"
echo " Out  : $RESULTS_JSON"
echo "================================================================"

# ── write_failure_json must be defined before any early-exit calls ───────────
write_failure_json() {
    local err_code="$1"
    local err_msg="$2"
    cat > "$RESULTS_JSON" <<EOF
{
  "scanned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "chain": "omnibus-regtest",
  "host": "$(uname -s -r 2>/dev/null || echo 'unknown') / $(uname -m 2>/dev/null || echo 'unknown')",
  "error": {
    "code": "${err_code}",
    "message": "${err_msg}"
  },
  "tests": null
}
EOF
}

# ── Sanity: binary exists ────────────────────────────────────────────────────
if [ ! -x "$NODE_BIN" ]; then
    echo "[FATAL] Node binary not found / not executable: $NODE_BIN"
    write_failure_json "binary_missing" "Node binary not found at $NODE_BIN"
    exit 1
fi

# ── Sanity: RPC port 8332 must be free (else there's a mainnet node running) ─
PORT_OWNER=$(powershell.exe -Command "(Get-NetTCPConnection -LocalPort $RPC_PORT -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess" 2>/dev/null | tr -d '\r\n ')
if [ -n "$PORT_OWNER" ] && [ "$PORT_OWNER" != "0" ]; then
    PROC_NAME=$(powershell.exe -Command "(Get-Process -Id $PORT_OWNER -ErrorAction SilentlyContinue).ProcessName" 2>/dev/null | tr -d '\r\n ')
    echo "[FATAL] RPC port $RPC_PORT is already bound by PID=$PORT_OWNER (proc=$PROC_NAME)"
    echo "        This is likely your mainnet node — the scanner will NOT kill it."
    echo "        Stop it manually and rerun, OR rebuild the node with a different RPC port."
    write_failure_json "rpc_port_busy" "RPC port $RPC_PORT is held by PID $PORT_OWNER ($PROC_NAME). Refusing to interfere with running node."
    exit 1
fi

# ── Backup mainnet DB (paranoia, regtest doesn't touch it) ───────────────────
if [ -f "$REPO_DIR/omnibus-chain.dat" ]; then
    BACKUP_NAME="omnibus-chain.dat.bench-backup-$(date +%H%M%S)"
    cp "$REPO_DIR/omnibus-chain.dat" "$REPO_DIR/$BACKUP_NAME" 2>/dev/null && \
        echo "[BACKUP] mainnet DB → $BACKUP_NAME"
fi

# ── Wipe any stale regtest DB so each run is fresh + idempotent ──────────────
rm -rf "$REPO_DIR/data/regtest" 2>/dev/null
mkdir -p "$REPO_DIR/data/regtest"

# ── Helpers ──────────────────────────────────────────────────────────────────
now_ms() {
    # Use bash builtin EPOCHREALTIME if available (bash 5+) — microsecond precision
    if [ -n "${EPOCHREALTIME:-}" ]; then
        # Format: 1234567890.123456 — convert to ms
        printf '%s\n' "$EPOCHREALTIME" | awk '{printf "%.0f\n", $1 * 1000}'
    else
        # Fallback: seconds * 1000 (ms granularity lost)
        echo $(($(date +%s) * 1000))
    fi
}

rpc_call() {
    # $1 = method, $2 = params JSON array (default [])
    local method="$1"
    local params="${2:-[]}"
    curl -s -X POST -H "Content-Type: application/json" \
         --max-time 5 \
         --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}" \
         "$RPC_URL" 2>/dev/null
}

rpc_ready() {
    local resp
    resp=$(rpc_call getblockcount)
    [[ "$resp" == *"\"result\""* ]]
}

# Extract "result" numeric value (works for getblockcount-style numeric results)
extract_result_int() {
    # Crude but works for {"jsonrpc":"2.0","id":1,"result":N}
    echo "$1" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
}

cleanup() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            echo "[CLEANUP] Killing OUR bench node PID $pid ..."
            # Windows-friendly kill — try TASKKILL via PowerShell as fallback
            kill "$pid" 2>/dev/null || powershell.exe -Command "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" 2>/dev/null
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
    # We deliberately do NOT kill anything else, even if it holds 8332/29500 —
    # it would be the user's mainnet node and we must never touch it.
}

trap cleanup EXIT INT TERM

# ── Detect host info for the report ──────────────────────────────────────────
HOST_DESC="$(uname -s 2>/dev/null) $(uname -r 2>/dev/null) $(uname -m 2>/dev/null)"

# Try to grab node version (look for VERSION constant in CHANGELOG or git tag)
NODE_VERSION="unknown"
if [ -f "$REPO_DIR/CHANGELOG.md" ]; then
    NODE_VERSION=$(grep -m1 -E '^##? \[?v[0-9]' "$REPO_DIR/CHANGELOG.md" 2>/dev/null | sed -n 's/.*v\([0-9.]*\).*/v\1/p' | head -1)
    [ -z "$NODE_VERSION" ] && NODE_VERSION="unknown"
fi

# ── Start the node ───────────────────────────────────────────────────────────
echo ""
echo "[START] Launching regtest seed node on RPC=${RPC_PORT}, P2P=${P2P_PORT} ..."

START_NS=$(now_ms)

# Launch in background. NB: --primary marks it as primary seed.
"$NODE_BIN" --mode seed --node-id bench --port "$P2P_PORT" --regtest --primary \
    > "$NODE_LOG" 2>&1 &
NODE_PID=$!
echo "$NODE_PID" > "$PID_FILE"
echo "[START] Node PID=$NODE_PID  log=$NODE_LOG"

# ── Wait for RPC ready ───────────────────────────────────────────────────────
echo "[WAIT] Polling RPC until ready (max 30s)..."
RPC_READY=false
for i in $(seq 1 60); do
    if rpc_ready; then
        RPC_READY=true
        break
    fi
    # Check the node process is still alive
    if ! kill -0 "$NODE_PID" 2>/dev/null; then
        echo "[FATAL] Node process died during startup. Last log lines:"
        tail -20 "$NODE_LOG" 2>&1 | sed 's/^/  | /'
        write_failure_json "node_died_at_startup" "Node process exited before RPC ready. See $NODE_LOG"
        exit 1
    fi
    sleep 0.5
done

READY_NS=$(now_ms)
STARTUP_MS=$((READY_NS - START_NS))

if [ "$RPC_READY" != "true" ]; then
    echo "[FATAL] RPC did not respond within 30s"
    tail -20 "$NODE_LOG" 2>&1 | sed 's/^/  | /'
    write_failure_json "rpc_timeout" "RPC did not respond within 30s"
    exit 1
fi

echo "[READY] RPC up after ${STARTUP_MS}ms"

# ── Capture idle RAM (before mining) ─────────────────────────────────────────
# PID from $NODE_PID is the bash subshell PID; the actual omnibus-node.exe is
# a child of it. Find the omnibus-node child by name to get the real WorkingSet.
RAM_MB_IDLE=$(powershell.exe -Command "[math]::Round((Get-Process omnibus-node -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1).WorkingSet64 / 1MB, 0)" 2>/dev/null | tr -d '\r\n ')
RAM_MB_IDLE=${RAM_MB_IDLE:-0}
echo "[MEM]  Idle RAM: ${RAM_MB_IDLE} MB"

# ── RPC latency benchmark ────────────────────────────────────────────────────
echo ""
echo "[RPC]  Measuring latency: ${RPC_SAMPLES} samples per method..."

RPC_JSON=""
declare -A RPC_AVG RPC_MIN RPC_MAX RPC_P50

for method in "${RPC_METHODS[@]}"; do
    # Pick params per method
    case "$method" in
        getbalance)        params='[]' ;;  # no-arg variant
        *)                 params='[]' ;;
    esac

    # Time RPC_SAMPLES sequential calls and record per-call latency
    local_min=999999
    local_max=0
    local_sum=0
    samples=()
    fail_count=0

    for i in $(seq 1 "$RPC_SAMPLES"); do
        t0=$(now_ms)
        resp=$(rpc_call "$method" "$params")
        t1=$(now_ms)
        dt=$((t1 - t0))
        if [ -z "$resp" ] || [[ "$resp" != *"\"result\""* ]] && [[ "$resp" != *"\"error\""* ]]; then
            fail_count=$((fail_count + 1))
            continue
        fi
        samples+=("$dt")
        local_sum=$((local_sum + dt))
        [ "$dt" -lt "$local_min" ] && local_min="$dt"
        [ "$dt" -gt "$local_max" ] && local_max="$dt"
    done

    n=${#samples[@]}
    if [ "$n" -eq 0 ]; then
        avg=0; min=0; max=0
    else
        avg=$((local_sum / n))
        min="$local_min"
        max="$local_max"
    fi

    printf '  %-20s avg=%4dms  min=%4dms  max=%4dms  ok=%3d/%d\n' \
        "$method" "$avg" "$min" "$max" "$n" "$RPC_SAMPLES"

    RPC_AVG[$method]=$avg
    RPC_MIN[$method]=$min
    RPC_MAX[$method]=$max
    RPC_JSON+=$(printf '"%s":{"avg_ms":%d,"min_ms":%d,"max_ms":%d,"samples":%d,"failed":%d},' \
        "$method" "$avg" "$min" "$max" "$n" "$fail_count")
done
RPC_JSON="${RPC_JSON%,}"  # strip trailing comma

# ── Block production: register 9 miners to unblock seed mining ──────────────
echo ""
echo "[MINE] Registering 9 fake miners to satisfy MIN_MINERS_FOR_MINING..."
for i in $(seq 1 9); do
    fake_addr="ob1qfakemine${i}xxxxxxxxxxxxxxxxxxxxxxxxxx"
    fake_nid="benchmate-${i}"
    rpc_call registerminer "[\"${fake_addr}\",\"${fake_nid}\"]" >/dev/null
done

# Verify miner count
mininfo=$(rpc_call getmininginfo)
echo "[MINE] getmininginfo (post-register): $(echo "$mininfo" | head -c 200)..."

# Get block height at T0
T0_RESP=$(rpc_call getblockcount)
H0=$(extract_result_int "$T0_RESP")
H0=${H0:-0}
T0_SEC=$(date +%s)
echo "[MINE] H0=${H0} at T0=${T0_SEC}, mining for ${MINING_WINDOW_SEC}s..."

# Capture RAM during mining (sample mid-window)
sleep $((MINING_WINDOW_SEC / 2))
RAM_MB_MINING=$(powershell.exe -Command "[math]::Round((Get-Process omnibus-node -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1).WorkingSet64 / 1MB, 0)" 2>/dev/null | tr -d '\r\n ')
RAM_MB_MINING=${RAM_MB_MINING:-0}
CPU_PCT=$(powershell.exe -Command "[math]::Round((Get-Process omnibus-node -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1).CPU, 2)" 2>/dev/null | tr -d '\r\n ')
sleep $((MINING_WINDOW_SEC - MINING_WINDOW_SEC / 2))

T1_RESP=$(rpc_call getblockcount)
H1=$(extract_result_int "$T1_RESP")
H1=${H1:-$H0}
T1_SEC=$(date +%s)
ELAPSED=$((T1_SEC - T0_SEC))
[ "$ELAPSED" -lt 1 ] && ELAPSED=1
BLOCKS_MINED=$((H1 - H0))

# Compute blocks/sec * 1000 for integer math, format as float later
BPS_X1000=$(( (BLOCKS_MINED * 1000) / ELAPSED ))
# Computed observed block time (ms per block); guard divide-by-zero
if [ "$BLOCKS_MINED" -gt 0 ]; then
    OBS_BLOCK_MS=$(( (ELAPSED * 1000) / BLOCKS_MINED ))
else
    OBS_BLOCK_MS=0
fi

echo "[MINE] H1=${H1}, mined ${BLOCKS_MINED} blocks in ${ELAPSED}s"
echo "[MEM]  Mining RAM: ${RAM_MB_MINING} MB   CPU(cumulative): ${CPU_PCT:-n/a}"

# ── Find top 3 fastest RPC methods ──────────────────────────────────────────
TOP_RPC=$(for m in "${!RPC_AVG[@]}"; do echo "${RPC_AVG[$m]} $m"; done | sort -n | head -3 | awk '{print $2}' | paste -sd ',' -)

# ── Capture log tail for raw_outputs ─────────────────────────────────────────
LOG_TAIL=$(tail -30 "$NODE_LOG" 2>/dev/null | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 1500)
SAMPLE_RPC_RESP=$(rpc_call getblockchaininfo | head -c 800 | sed 's/"/\\"/g')

# ── Write JSON ───────────────────────────────────────────────────────────────
cat > "$RESULTS_JSON" <<EOF
{
  "scanned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "chain": "omnibus-regtest",
  "node_version": "${NODE_VERSION}",
  "host": "${HOST_DESC}",
  "node_pid": ${NODE_PID},
  "ports": {
    "rpc": ${RPC_PORT},
    "p2p": ${P2P_PORT}
  },
  "tests": {
    "startup_time_ms": ${STARTUP_MS},
    "rpc_latency_ms": {${RPC_JSON}},
    "block_production": {
      "regtest": {
        "blocks_mined": ${BLOCKS_MINED},
        "elapsed_seconds": ${ELAPSED},
        "blocks_per_second": $(awk -v b="$BLOCKS_MINED" -v e="$ELAPSED" 'BEGIN{printf "%.3f", (e>0)?b/e:0}'),
        "block_time_ms_observed": ${OBS_BLOCK_MS},
        "block_time_ms_configured": 100,
        "height_t0": ${H0},
        "height_t1": ${H1}
      }
    },
    "resource_usage": {
      "ram_mb_idle": ${RAM_MB_IDLE},
      "ram_mb_mining": ${RAM_MB_MINING},
      "cpu_seconds_cumulative": ${CPU_PCT:-0}
    },
    "fastest_rpc_methods": "${TOP_RPC}"
  },
  "raw_outputs": {
    "node_log_path": "$(echo "$NODE_LOG" | sed 's/\\/\\\\/g')",
    "log_tail": "${LOG_TAIL}",
    "rpc_sample_getblockchaininfo": "${SAMPLE_RPC_RESP}"
  }
}
EOF

echo ""
echo "================================================================"
echo " RESULTS written to: $RESULTS_JSON"
echo "================================================================"
cat "$RESULTS_JSON"

exit 0
