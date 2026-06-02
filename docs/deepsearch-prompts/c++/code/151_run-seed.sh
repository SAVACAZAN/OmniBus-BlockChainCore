// OEP-1 146/150 | path=scripts/run-miner.sh | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#!/bin/bash
# OEP-1 146/150 | path=scripts/run-miner.sh | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1

./build/omnibus-node \
    --mode miner \
    --network mainnet \
    --p2p-port 9001 \
    --rpc-port 8333 \
    --ws-port 8335 \
    --evm-port 8334 \
    --seed-host 127.0.0.1 \
    --seed-port 9000 \
    --data-dir ./data/miner \
    --verbose