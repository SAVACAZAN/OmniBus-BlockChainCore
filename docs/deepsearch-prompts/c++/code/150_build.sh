// OEP-1 145/150 | path=scripts/run-seed.sh | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#!/bin/bash
# OEP-1 145/150 | path=scripts/run-seed.sh | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1

./build/omnibus-node \
    --mode seed \
    --network mainnet \
    --p2p-port 9000 \
    --rpc-port 8332 \
    --ws-port 8334 \
    --evm-port 8333 \
    --data-dir ./data/seed \
    --verbose