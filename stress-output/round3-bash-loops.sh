#!/usr/bin/env bash
# Round 3: rotate through bash test scripts on both chains
# Per the user's plan, run scripts 01-12 multiple times alternating chains.
set -u
ROOT="/c/Kits work/limaje de programare/1_CORE/BlockChainCore"
TS_DIR="$ROOT/test-scripts"
OUT="$ROOT/stress-output"
LOG="$OUT/round3.log"
SUMMARY="$OUT/round3-summary.csv"

date "+[%Y-%m-%dT%H:%M:%S] === ROUND 3 START ===" >> "$LOG"

# CSV header
[ -f "$SUMMARY" ] || echo "ts,chain,script,iter,pass,fail,skip,duration_s" > "$SUMMARY"

# Build counters
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

run_script() {
    local script="$1"
    local chain="$2"
    local iter="$3"
    local t0=$(date +%s)
    local out=$(CHAIN="$chain" bash "$TS_DIR/$script" -q 2>&1)
    local t1=$(date +%s)
    local dur=$((t1 - t0))
    # Parse summary line: "pass: X   fail: Y   skip: Z"
    local pass=$(echo "$out" | grep -oE "pass: [0-9]+" | grep -oE "[0-9]+" | tail -1)
    local fail=$(echo "$out" | grep -oE "fail: [0-9]+" | grep -oE "[0-9]+" | tail -1)
    local skip=$(echo "$out" | grep -oE "skip: [0-9]+" | grep -oE "[0-9]+" | tail -1)
    pass=${pass:-0}; fail=${fail:-0}; skip=${skip:-0}
    local now=$(date "+%Y-%m-%dT%H:%M:%S")
    echo "$now,$chain,$script,$iter,$pass,$fail,$skip,$dur" >> "$SUMMARY"
    echo "[$now] $script $chain iter=$iter -> pass=$pass fail=$fail skip=$skip (${dur}s)" >> "$LOG"
    echo "  $script $chain iter=$iter -> pass=$pass fail=$fail skip=$skip (${dur}s)"
    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))
}

SCRIPTS=(
    "01-chain-basic.sh"
    "02-reputation.sh"
    "03-stake-validators.sh"
    "04-agents.sh"
    "05-names.sh"
    "06-exchange.sh"
    "07-grid.sh"
    "08-htlc-swap.sh"
    "09-oracle.sh"
    "10-notarize-sub.sh"
    "11-escrow-channels.sh"
    "12-governance.sh"
)

# Run 5 iterations of all 12 scripts on both chains = 12*5*2 = 120 script-runs
for iter in 1 2 3 4 5; do
    echo "=== ITERATION $iter ==="
    for chain in mainnet testnet; do
        for script in "${SCRIPTS[@]}"; do
            run_script "$script" "$chain" "$iter"
        done
    done
done

echo "[$(date "+%Y-%m-%dT%H:%M:%S")] === ROUND 3 END (total pass=$TOTAL_PASS fail=$TOTAL_FAIL skip=$TOTAL_SKIP) ===" >> "$LOG"
echo "ROUND 3 DONE: pass=$TOTAL_PASS fail=$TOTAL_FAIL skip=$TOTAL_SKIP"
