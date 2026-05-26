#!/bin/bash
# Deploy OmniBus to VPS — restart node + frontend cleanly.
# Run from C:\Kits work\limaje de programare\1_CORE\BlockChainCore\
#
# Usage: bash deploy-vps.sh
#   or:  bash deploy-vps.sh --build   (rebuild Zig binary on VPS first)
#   or:  bash deploy-vps.sh --frontend (deploy frontend only, faster)

set -e

VPS=omnibus-vps
REMOTE_DIR=~/omnibus-blockchain

echo "=== OmniBus VPS Deploy ==="
echo

MODE="${1:-default}"

# ─── 1. Sync source files ─────────────────────────────────────────────
if [ "$MODE" != "--frontend" ]; then
    echo "→ Syncing core/*.zig files..."
    scp -q core/*.zig $VPS:$REMOTE_DIR/core/
fi

echo "→ Syncing frontend/src/..."
rsync -az --delete -e ssh frontend/src/ $VPS:$REMOTE_DIR/frontend/src/ 2>/dev/null || \
    scp -qr frontend/src/* $VPS:$REMOTE_DIR/frontend/src/

# ─── 2. Optional rebuild ──────────────────────────────────────────────
if [ "$MODE" = "--build" ]; then
    echo "→ Rebuilding Zig binary on VPS..."
    ssh $VPS "cd $REMOTE_DIR && zig build -Doqs=false 2>&1 | tail -3"
fi

# ─── 3. Restart node (mainnet only — single-instance lock allows only 1) ──
if [ "$MODE" != "--frontend" ]; then
    echo "→ Restarting omnibus-node (mainnet)..."
    ssh $VPS "
        killall omnibus-node 2>/dev/null
        sleep 2
        rm -f /tmp/omnibus-miner.lock
        cd $REMOTE_DIR
        nohup ./zig-out/bin/omnibus-node --mode seed --node-id node-1 --port 9000 --chain mainnet > /tmp/seed.log 2>&1 &
        sleep 2
        nohup ./zig-out/bin/omnibus-node --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9000 --chain mainnet > /tmp/miner.log 2>&1 &
        sleep 1
        echo \"Nodes started: \$(pgrep -c omnibus-node) processes\"
    "
fi

# ─── 4. Restart Vite (frontend HMR) ───────────────────────────────────
echo "→ Restarting Vite frontend..."
ssh $VPS "
    pkill -f 'vite --host' 2>/dev/null
    sleep 2
    cd $REMOTE_DIR/frontend
    nohup node node_modules/.bin/vite --host 0.0.0.0 --port 8888 > /tmp/vite.log 2>&1 &
    sleep 3
    if pgrep -f 'vite --host' > /dev/null; then
        echo \"Vite started OK on port 8888\"
    else
        echo \"ERROR: Vite failed to start\"
        tail -20 /tmp/vite.log
        exit 1
    fi
"

# ─── 5. Health check ──────────────────────────────────────────────────
echo
echo "→ Health check..."
ssh $VPS "
    BLOCK=\$(curl -s -X POST http://localhost:8332 -H 'Content-Type: application/json' \
        -d '{\"jsonrpc\":\"2.0\",\"method\":\"getblockcount\",\"params\":[],\"id\":1}' | \
        python3 -c 'import sys,json; print(json.load(sys.stdin)[\"result\"])' 2>/dev/null || echo 'down')
    FAUCET=\$(curl -s -X POST http://localhost:8332 -H 'Content-Type: application/json' \
        -d '{\"jsonrpc\":\"2.0\",\"method\":\"getfaucetstatus\",\"params\":{},\"id\":1}' | \
        python3 -c 'import sys,json; r=json.load(sys.stdin)[\"result\"]; print(f\"enabled={r[chr(101)+chr(110)+chr(97)+chr(98)+chr(108)+chr(101)+chr(100)]}, balance={r[chr(98)+chr(97)+chr(108)+chr(97)+chr(110)+chr(99)+chr(101)]}\")' 2>/dev/null || echo 'down')
    HTTP=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8888/ || echo 'down')
    echo \"  Block height:  \$BLOCK\"
    echo \"  Faucet:        \$FAUCET\"
    echo \"  Vite frontend: HTTP \$HTTP\"
"

echo
echo "=== Done. Open https://omnibusblockchain.cc:8443/ and Ctrl+Shift+R ==="
