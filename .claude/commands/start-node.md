# /start-node

Launch the OmniBus seed node.

## Steps

1. Build if needed: `zig build`
2. Run seed node:
```bash
./zig-out/bin/omnibus-node --port 19000 --data-dir data/seed
```

## Options

- `--port 19000` — P2P port
- `--rpc-port 8332` — JSON-RPC port
- `--ws-port 8334` — WebSocket port
- `--bootstrap none` — Start as seed

## Verify

Check logs for `Listening on 0.0.0.0:19000`.
