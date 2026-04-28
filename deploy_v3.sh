#!/usr/bin/env bash
# Deploy V3 binary to VPS, restart, run smoke test.
# Run this AFTER stopping local HodLum miner so binary can be overwritten.
set -euo pipefail

ROOT="/c/Kits work/limaje de programare/1_CORE/BlockChainCore"
cd "$ROOT"

echo "=== Step 1/5: Verify HodLum miner stopped ==="
if tasklist 2>/dev/null | grep -q omnibus-node; then
  echo "  ERROR: omnibus-node.exe still running. Stop HodLum (Ctrl+C) first."
  echo "  Running PIDs:"
  tasklist 2>/dev/null | grep omnibus-node || true
  exit 1
fi
echo "  OK: no omnibus-node running"

echo
echo "=== Step 2/5: Build V3 binary (without liboqs) ==="
zig build -Doqs=false 2>&1 | tail -20
if [[ ! -f zig-out/bin/omnibus-node.exe ]]; then
  echo "  ERROR: build failed, no binary"
  exit 1
fi
echo "  OK: $(ls -la zig-out/bin/omnibus-node.exe | awk '{print $5, $9}')"

echo
echo "=== Step 3/5: Wipe local chain.dat (V2 residue) ==="
TESTNET_DAT="$LOCALAPPDATA/lcx-liberty-suite/omnibus-node/data/testnet/chain.dat"
if [[ -f "$TESTNET_DAT" ]]; then
  rm -f "$TESTNET_DAT"
  echo "  WIPED: $TESTNET_DAT"
else
  echo "  (no local chain.dat to wipe)"
fi

echo
echo "=== Step 4/5: Deploy to VPS ==="
echo "  TODO: scp + ssh restart — needs your SSH key/host config."
echo "  Manual steps for now:"
echo "    scp zig-out/bin/omnibus-node.exe alex@38.143.19.97:/opt/omnibus/"
echo "    ssh alex@38.143.19.97 'sudo systemctl restart omnibus-testnet'"
echo "    ssh alex@38.143.19.97 'rm -f /var/lib/omnibus/testnet/chain.dat'"
echo "    (chain.dat wipe BEFORE restart so VPS regenesises)"

echo
echo "=== Step 5/5: After both nodes restarted, run smoke test ==="
echo "  bash test_v3_e2e.sh"
