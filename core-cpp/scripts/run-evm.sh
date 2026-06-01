#!/bin/bash
# OEP-1 147/150 | path=scripts/run-evm.sh | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1

./build/omnibus-node \
    --mode evm \
    --network mainnet \
    --p2p-port 9002 \
    --rpc-port 8334 \
    --ws-port 8336 \
    --evm-port 8333 \
    --seed-host 127.0.0.1 \
    --seed-port 9000 \
    --data-dir ./data/evm \
    --verbose