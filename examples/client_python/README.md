# OmniBus Python Franchise Client

This folder shows how a third-party application talks to OmniBus.

The chain is **infrastructure**: it accepts connections from any client
that speaks JSON-RPC 2.0 over HTTP. There is no special SDK and no
shared library — write your client in whatever language you prefer.

## Quick start

```bash
pip install requests
python3 franchise_client.py
```

This connects to the public testnet endpoint at
`https://omnibusblockchain.cc:8443/api-testnet/`, prints the chain
height, generates a demo mnemonic, calls the faucet, watches the
balance for 30 seconds, and exits.

## What the chain exposes

| Surface | Address | Notes |
|---------|---------|-------|
| JSON-RPC 2.0 | `/api-testnet/` (public) | Bitcoin-Core-style methods + OmniBus extensions |
| REST exchange | `/exchange/0/{public,private}/*` | Kraken-compatible REST surface |
| WebSocket | `/ws-testnet` | Live block + tx broadcasts |
| HTTPS | `:8443` | nginx terminates TLS, proxies to backend |

## What the chain does NOT do

- No agents in the chain process. AI strategies run in **your** client.
- No price oracle in the chain process. Feed your own prices via
  `submitprice` if you want; otherwise the chain stays neutral.
- No matching engine in your wallet. Server enforces signatures,
  nonces, balances, fees on the chain side. You can't cheat by
  writing a custom client.

## The franchise model

Like Bitcoin Core: anyone runs a node, anyone connects with whatever
client they prefer. The on-chain rules are the same for everyone —
that's the only thing the chain enforces.

To plug in your own client:

1. Open a TCP/HTTPS connection to the public RPC endpoint.
2. POST a JSON-RPC 2.0 envelope:
   ```json
   {"jsonrpc": "2.0", "id": 1, "method": "getblockcount", "params": []}
   ```
3. Read the JSON response.
4. Repeat.

That's it. Whether you call from Python, Rust, a browser `fetch()`, or
a shell `curl` loop, the chain treats you the same.

## Endpoint cheat-sheet

Read-only:
- `getblockcount` — chain tip height
- `getblock(hash_or_height)` — full block
- `getaddressbalance({address})` — balance in sat
- `gettransaction(txid)` — TX detail
- `getmempoolsize` — pending TX count

Write (all signed by the caller):
- `sendrawtransaction({tx_hex})` — submit a signed TX
- `claimfaucet({address})` — testnet faucet (1 OMNI, rate-limited per IP/addr)

Exchange REST (Kraken-style):
- `GET /exchange/0/public/Depth?pair=OMNI/USDC` — orderbook
- `POST /exchange/0/private/AddOrder` — place signed order
- `POST /exchange/0/private/CancelOrder` — cancel by id
- `POST /exchange/0/private/Balance` — your balances

## Building your own franchisee

The full happy path for a trading bot is:

1. **Connect** — open RPC + WS connections.
2. **Authenticate** — derive keypair from mnemonic (BIP-32/39).
3. **Fund** — claim faucet on testnet, or receive on mainnet.
4. **Mine (optional)** — run a miner if you want OMNI directly.
5. **Place orders** — sign EXCHANGE_PLACE_V1 payload, POST AddOrder.
6. **Listen** — subscribe to WS for fill events.
7. **Withdraw / send** — sign a normal TX, POST sendrawtransaction.

The chain doesn't care which steps you skip or how you implement
them. Strategy, scheduling, retries, error handling, UI — all yours.

## See also

- `franchise_client.py` — minimal demo of steps 1-3 in this list
- `examples/agent.json` — sample multi-agent config (for nodes that
  *do* opt into running agents in-process via `--agent-config`)
- `swagger.json` (in `frontend/public/`) — OpenAPI spec for the REST
  surface, including all 42 exchange endpoints
