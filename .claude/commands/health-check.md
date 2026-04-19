# /health-check

Check node status via JSON-RPC.

## Steps

1. Ensure node is running (`/start-node`)
2. Query health:
```bash
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}'
```

## Automated Script

```bash
python3 tools/AI/network-health-scorer.py --peers 8 --propagation-ms 150 --mempool 1200
```

## Expected Healthy Output

- `peer_count >= 8`
- `propagation_ms < 500`
- `mempool_size > 100`
- `total_score >= 80`
