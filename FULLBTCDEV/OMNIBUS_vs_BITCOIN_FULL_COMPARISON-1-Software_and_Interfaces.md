# 1. Software & Interfaces

> OmniBus vs Bitcoin — Category 1/10
> Generated: 2026-03-31 16:50

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 1 | bitcoind (daemon) | Y | Y | main.zig | Entry point, single-instance lock |
| 2 | Bitcoin-Qt (GUI) | Y | P | frontend/ | We have React frontend instead |
| 3 | bitcoin-cli (CLI) | Y | Y | cli.zig | --mode, --node-id, --port |
| 4 | RPC Server (JSON-RPC) | Y | Y | rpc_server.zig | Port 8332, HTTP |
| 5 | REST Interface | Y | Y | rpc_server.zig | Combined with RPC |
| 6 | WebSocket Server | N | + | ws_server.zig | Push events, port 8334 [EXTRA] |
| 7 | Mempool | Y | Y | mempool.zig | FIFO, size/time limits |
| 8 | Database / LevelDB | Y | Y | database.zig | Custom binary, not LevelDB |
| 9 | Validation Engine | Y | Y | consensus.zig | PoW + Casper FFG |
| 10 | Full Node | Y | Y | main.zig | Seed + Miner mode |
| 11 | Pruned Node | Y | Y | prune_config.zig | Configurable pruning |
| 12 | Light Client (SPV) | Y | Y | light_client.zig | Header-only verification |
| 13 | Blockchain Explorer | Y | P | frontend/ | React BlockExplorer component |
| 14 | Mainnet Config | Y | Y | chain_config.zig | Magic: "OMNI" |
| 15 | Testnet Config | Y | Y | chain_config.zig | Magic: "TEST" |
| 16 | Regtest Config | Y | Y | chain_config.zig | Magic: "REGT" |
| 17 | Signet / Devnet | Y | Y | chain_config.zig | Magic: "DEVN" |
| 18 | Wallet.dat / DB file | Y | Y | database.zig | omnibus-chain.dat |
| 19 | Chainstate (UTXO/State) | Y | Y | state_trie.zig | State trie (hybrid) |
| 20 | Peer Discovery | Y | Y | bootstrap.zig | DHT + DNS seeds |

---

**BTC has: 19 items**
**OmniBus: 18 implemented, 2 partial, 0 missing, 1 extras**
**Score: 94%** (18/19 BTC features + 1 unique extras)

### Extras (OmniBus-only):
- WebSocket Server — Push events, port 8334 [EXTRA]

