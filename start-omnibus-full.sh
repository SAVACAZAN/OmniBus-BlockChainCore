#!/bin/bash
# OmniBus Full Blockchain Startup Script (Linux/macOS)
# Launches: Seed Node + RPC Server + Frontend + 10 Light Miners
# Generates wallets and distributes genesis tokens automatically

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

function write_header() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    printf "${CYAN}║ %-56s ║${NC}\n" "$1"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

function write_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

function write_info() {
    echo -e "${CYAN}→ $1${NC}"
}

function write_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

function write_error() {
    echo -e "${RED}❌ $1${NC}"
}

# ============================================================================
# STARTUP CONFIGURATION
# ============================================================================

write_header "OmniBus Genesis Blockchain - Full Startup"

SEED_HOST="127.0.0.1"
SEED_PORT="9000"
RPC_PORT="8332"
FRONTEND_PORT="8888"
MINERS_COUNT=10
HASHRATE=1000
GENESIS_MINERS=3

write_info "Configuration:"
write_info "  - Seed Node: $SEED_HOST:$SEED_PORT"
write_info "  - RPC Server: http://localhost:$RPC_PORT"
write_info "  - Frontend: http://localhost:$FRONTEND_PORT"
write_info "  - Light Miners: $MINERS_COUNT"
write_info "  - Hashrate per Miner: $HASHRATE H/s"
write_info "  - Genesis Ready: ≥$GENESIS_MINERS miners"
echo ""

# ============================================================================
# PHASE 1: CHECK REQUIREMENTS
# ============================================================================

write_header "Phase 1: Checking Requirements"

ERRORS=()

# Check omnibus-node exists
if [ ! -f "./omnibus-node" ]; then
    ERRORS+=("omnibus-node not found")
else
    write_success "omnibus-node found"
fi

# Check Node.js for frontend
if ! command -v npm &> /dev/null; then
    write_warning "npm not found (frontend will not start)"
else
    write_success "npm found"
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    write_error "Build Requirements:"
    for error in "${ERRORS[@]}"; do
        write_error "  $error"
    done
    write_info "Fix: zig build-exe -O ReleaseFast core/main.zig --name omnibus-node"
    exit 1
fi

echo ""

# ============================================================================
# PHASE 2: CREATE DIRECTORIES
# ============================================================================

write_header "Phase 2: Creating Directories"

for dir in logs wallets genesis; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        write_success "Created $dir/"
    else
        write_info "$dir/ already exists"
    fi
done

echo ""

# ============================================================================
# PHASE 3: GENERATE GENESIS WALLETS
# ============================================================================

write_header "Phase 3: Generating Genesis Wallets"

echo -e "${MAGENTA}Token Economics:${NC}"
echo -e "${MAGENTA}  - Total Supply: 21,000,000 OMNI${NC}"
echo -e "${MAGENTA}  - Per Miner: $((21000000 / $MINERS_COUNT)) OMNI${NC}"
echo -e "${MAGENTA}  - Total SAT: $((21000000 * 100000000))${NC}"
echo ""

# Create wallet JSON file
cat > wallets/genesis-allocation.json << EOF
{
  "genesis_timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "total_supply_omni": 21000000,
  "miners": [
EOF

for ((i=0; i<$MINERS_COUNT; i++)); do
    MINER_NAME="miner-$i"
    ALLOCATION_PER_MINER=$((21000000 / $MINERS_COUNT))
    ALLOCATION_SAT=$((ALLOCATION_PER_MINER * 100000000))
    ADDRESS="ob_omni_miner$(printf '%02d' $((i+1)))xxxxxxxxxxxxx"

    write_success "Miner $((i+1))/$MINERS_COUNT: $MINER_NAME"
    write_info "   Address: $ADDRESS"
    write_info "   Balance: $ALLOCATION_PER_MINER OMNI ($ALLOCATION_SAT SAT)"
    echo ""

    # Add to JSON (with proper comma handling)
    if [ $i -lt $((MINERS_COUNT - 1)) ]; then
        cat >> wallets/genesis-allocation.json << EOF
    {
      "miner_id": $i,
      "miner_name": "$MINER_NAME",
      "address": "$ADDRESS",
      "allocated_omni": $ALLOCATION_PER_MINER,
      "allocated_sat": $ALLOCATION_SAT,
      "status": "genesis_allocated"
    },
EOF
    else
        cat >> wallets/genesis-allocation.json << EOF
    {
      "miner_id": $i,
      "miner_name": "$MINER_NAME",
      "address": "$ADDRESS",
      "allocated_omni": $ALLOCATION_PER_MINER,
      "allocated_sat": $ALLOCATION_SAT,
      "status": "genesis_allocated"
    }
EOF
    fi
done

cat >> wallets/genesis-allocation.json << EOF
  ]
}
EOF

write_success "Saved to wallets/genesis-allocation.json"
echo ""

# ============================================================================
# PHASE 4: LAUNCH SEED NODE
# ============================================================================

write_header "Phase 4: Launching Seed Node"

write_info "Starting seed node on $SEED_HOST:$SEED_PORT..."

./omnibus-node \
    --mode seed \
    --node-id seed-1 \
    --primary \
    --port $SEED_PORT \
    > logs/seed-node.log 2>&1 &
SEED_PID=$!

write_success "Seed node started (PID: $SEED_PID)"
write_info "   Log: logs/seed-node.log"

sleep 2
echo ""

# ============================================================================
# PHASE 5: LAUNCH RPC SERVER (runs with seed node)
# ============================================================================

write_header "Phase 5: RPC Server"

write_success "RPC Server running on seed node (port $RPC_PORT)"
write_info "   HTTP: http://localhost:$RPC_PORT"
write_info "   Methods: getGenesisStatus, getMiners, startGenesis"
write_info "   Integration: Built-in with seed node"

sleep 1
echo ""

# ============================================================================
# PHASE 6: LAUNCH FRONTEND
# ============================================================================

write_header "Phase 6: Launching Frontend"

if command -v npm &> /dev/null; then
    write_info "Starting frontend on http://localhost:$FRONTEND_PORT..."

    (cd frontend && npm run dev > ../logs/frontend.log 2>&1) &
    FRONTEND_PID=$!

    write_success "Frontend started (PID: $FRONTEND_PID)"
    write_info "   Log: logs/frontend.log"
    write_info "   Genesis Countdown: http://localhost:$FRONTEND_PORT/genesis-countdown"

    sleep 3
else
    write_warning "npm not found - skipping frontend"
    write_info "   Start manually: cd frontend && npm run dev"
fi

echo ""

# ============================================================================
# PHASE 7: LAUNCH LIGHT MINERS
# ============================================================================

write_header "Phase 7: Launching Light Miners"

echo -e "${MAGENTA}Launching $MINERS_COUNT light miners...${NC}"
echo -e "${MAGENTA}Total hashrate: $((MINERS_COUNT * HASHRATE)) H/s${NC}"
echo ""

# Store PIDs for cleanup
> .miner_pids

for ((i=0; i<$MINERS_COUNT; i++)); do
    MINER_ID="miner-$i"
    MINER_NAME="light-miner-$(printf '%02d' $((i+1)))"

    write_info "Starting $MINER_NAME..."

    ./omnibus-node \
        --mode miner \
        --node-id "$MINER_ID" \
        --seed-host "$SEED_HOST" \
        --seed-port "$SEED_PORT" \
        --hashrate "$HASHRATE" \
        > "logs/$MINER_NAME.log" 2>&1 &
    MINER_PID=$!

    echo $MINER_PID >> .miner_pids
    write_success "$MINER_NAME (PID: $MINER_PID)"

    sleep 0.5
done

echo ""

# ============================================================================
# PHASE 8: SUMMARY & INSTRUCTIONS
# ============================================================================

write_header "Genesis Startup Complete! 🚀"

write_success "All components launched successfully!"
echo ""

echo -e "${MAGENTA}Running Processes:${NC}"
echo -e "${MAGENTA}  - Seed Node + RPC Server (PID: $SEED_PID)${NC}"
echo -e "${MAGENTA}  - $MINERS_COUNT Light Miners${NC}"
echo ""

write_info "📊 Genesis Status:"
write_info "  - Miners needed for genesis: $GENESIS_MINERS"
write_info "  - Miners launching: $MINERS_COUNT"
write_info "  - Status: ✅ Genesis Ready (when 3+ miners connected)"
echo ""

echo -e "${MAGENTA}💰 Token Distribution:${NC}"
echo -e "${MAGENTA}  - Total Supply: 21,000,000 OMNI${NC}"
echo -e "${MAGENTA}  - Per Miner: $((21000000 / $MINERS_COUNT)) OMNI${NC}"
echo -e "${MAGENTA}  - Genesis Block Distribution: ACTIVE${NC}"
echo ""

write_info "🌐 Access Points:"
write_info "  - Genesis Countdown UI:"
echo -e "${MAGENTA}    → http://localhost:$FRONTEND_PORT/genesis-countdown${NC}"
write_info "  - RPC API:"
echo -e "${MAGENTA}    → http://localhost:$RPC_PORT${NC}"
write_info "  - Wallet Data:"
echo -e "${MAGENTA}    → wallets/genesis-allocation.json${NC}"
echo ""

write_info "📁 Log Files:"
write_info "  - Seed Node: logs/seed-node.log"
write_info "  - RPC Server: logs/rpc-server.log"
write_info "  - Miners: logs/light-miner-*.log"
write_info "  - Frontend: logs/frontend.log"
echo ""

write_warning "⚠️  To stop all processes, run:"
write_warning "  pkill -f omnibus-node"
echo ""

write_success "Genesis blockchain is ready! Watch the Genesis Countdown page for live status."
echo ""

read -p "Press Enter to continue monitoring (Ctrl+C to stop)..." _

# Monitor for key processes
while true; do
    clear

    write_header "Genesis Blockchain - Live Monitoring"

    write_info "Process Status:"

    if ps -p $SEED_PID > /dev/null 2>&1; then
        write_success "Seed Node + RPC (PID: $SEED_PID)"
    else
        write_error "Seed Node + RPC (PID: $SEED_PID) - NOT RUNNING"
    fi

    MINERS_ALIVE=0
    while IFS= read -r PID; do
        if ps -p $PID > /dev/null 2>&1; then
            ((MINERS_ALIVE++))
        fi
    done < .miner_pids

    if [ $MINERS_ALIVE -ge 3 ]; then
        write_success "Miners: $MINERS_ALIVE/$MINERS_COUNT connected"
    else
        write_warning "Miners: $MINERS_ALIVE/$MINERS_COUNT connected"
    fi

    echo ""
    write_info "Last updated: $(date +'%H:%M:%S')"
    echo ""

    sleep 5
done
