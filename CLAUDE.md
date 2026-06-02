# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Multi-implementation node

BlockChainCore has TWO sibling node implementations of the same protocol (like reth ↔ geth for Ethereum):

| Impl | Path | Lang | Native RPC | EVM RPC | Status |
|---|---|---|---|---|---|
| **Zig (primary)** | `core/` | Zig 0.15.2 | port 8332 | — (FFI staticlib `evm/` deprecated 2026-06-01) | Live |
| **Rust (sibling)** | `core-rust/` | Rust 2021 | extends 8332 | port 8333 | Skeleton — ported 2026-06-01, integration in progress |

Both speak the **same wire protocol** and produce the **same chain hashes** so they can peer with each other. EVM execution is built-into `core-rust/` natively (revm + omnibus-crypto-core for PQ), no separate sidecar.

See `core-rust/README.md` for build instructions.

## Build & Run (Zig — primary)

Requires **Zig 0.15.2+** and **liboqs** compiled with MinGW at `C:/Kits work/limaje de programare/liboqs-src/build/`.

```bash
# Build the node binary (outputs zig-out/bin/omnibus-node.exe)
zig build

# Build without liboqs (disables PQ wallet features)
zig build -Doqs=false

# Run the blockchain node
zig build run
# Or directly:
./zig-out/bin/omnibus-node.exe --mode seed --node-id node-1 --port 9000
./zig-out/bin/omnibus-node.exe --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9000
```

## Testing

Tests are embedded in each `core/*.zig` file (Zig's `test` blocks). The build system defines grouped test steps:

```bash
zig build test              # All tests (without liboqs)
zig build test-crypto       # secp256k1, BIP32, ripemd160, schnorr, multisig, BLS, peer scoring, etc.
zig build test-chain        # block, blockchain, genesis, mempool, consensus, finality, governance, e2e mining
zig build test-net          # RPC, P2P, sync, network, node launcher, bootstrap, CLI, vault reader
zig build test-shard        # sub-blocks, shard config, blockchain v2
zig build test-storage      # storage, binary codec, archive, prune config, state trie, compact TX, witness
zig build test-light        # light client, light miner, mining pool, key encryption
zig build test-pq           # PQ crypto pure Zig (no liboqs)
zig build test-wallet       # wallet (requires liboqs)
```

To test a single module, run its file directly:
```bash
zig test core/secp256k1.zig
```

There are also standalone test files in `test/` (consensus_test.zig, mempool_test.zig, etc.) that can be run with `zig test test/<name>.zig`.

## Architecture

### Node Startup (core/main.zig)

`main.zig` is the entry point that orchestrates all subsystems in sequence:

1. **Single-instance lock** — OS-level lock prevents two miners on the same machine
2. **CLI parsing** (`cli.zig`) → mode (seed/miner), node-id, host, port, seed-host
3. **Vault reader** (`vault_reader.zig`) → reads mnemonic from SuperVault Named Pipe, env var, or dev default
4. **Database** (`database.zig`) → loads/persists blockchain state from `omnibus-chain.dat`
5. **Genesis** (`genesis.zig`) → initializes chain with official genesis block (mainnet or testnet config)
6. **Wallet** (`wallet.zig`) → derives wallet from mnemonic, 5 PQ address domains via liboqs
7. **Mempool** (`mempool.zig`) → FIFO transaction pool with size/time limits
8. **Consensus** (`consensus.zig`) → PoW engine with difficulty adjustment
9. **Metachain + Shards** (`metachain.zig`, `shard_coordinator.zig`) → 4-shard architecture
10. **Subsystems** — state trie, finality (Casper FFG), staking, governance, peer scoring, DNS registry, guardian
11. **P2P** (`p2p.zig`) → TCP transport, peer discovery, knock-knock duplicate detection
12. **WebSocket** (`ws_server.zig`) → push events to React frontend on port 8334
13. **RPC** (`rpc_server.zig`) → JSON-RPC 2.0 HTTP server on port 8332 (separate thread)
14. **Mining loop** — SubBlock engine (10 × 0.1s sub-blocks → 1 KeyBlock), then mine main block

### Core Layers

- **Crypto**: Pure Zig secp256k1 (`secp256k1.zig`), BIP-32 HD wallet (`bip32_wallet.zig`), RIPEMD-160 (`ripemd160.zig`), Schnorr signatures, BLS signatures, multisig. PQ crypto via liboqs C bindings (`pq_crypto.zig`, `wallet.zig`).
- **Consensus**: PoW with sub-block system (`sub_block.zig`), Casper FFG finality (`finality.zig`), governance voting (`governance.zig`), staking/validator system (`staking.zig`)
- **Networking**: TCP P2P (`p2p.zig`), node sync (`sync.zig`), Kademlia DHT (`kademlia_dht.zig`), peer scoring (`peer_scoring.zig`), bootstrap/discovery (`bootstrap.zig`)
- **Storage**: Binary codec (`binary_codec.zig`), archive manager (`archive_manager.zig`), state trie (`state_trie.zig`), compact blocks/transactions, witness data, pruning config

### Frontend (frontend/)

React + TypeScript app with Vite. Components: BlockExplorer, Wallet, Stats. Communicates via JSON-RPC (`api/rpc-client.ts`) to port 8332 and WebSocket on 8334.

### Each core/*.zig file is self-contained

Modules don't share a central module registry. Each file declares its own types and exports them. `main.zig` imports everything it needs directly. Tests live inside each file — no separate test runner needed.

## Key Parameters

| Parameter | Value | Source |
|-----------|-------|--------|
| Target block time | 1s | `consensus_params.zig::TARGET_BLOCK_TIME_S` |
| Sub-blocks per block | 10 (40ms interval) | `SUB_BLOCKS_PER_BLOCK`, `SUB_BLOCK_INTERVAL_MS` |
| RPC port | 8332 (HTTP) | — |
| WebSocket port | 8334 | — |
| P2P port | 9000+ (configurable) | — |
| EVM JSON-RPC port | 8333 (Rust impl) | `core-rust/src/main.rs` |
| Max supply | 21,000,000 OMNI | `MAX_SUPPLY_SAT = 21e15` |
| Block reward | 83,333,333 sat/block (~0.0833 OMNI = 50 OMNI / 600 blocks) | `BLOCK_REWARD_SAT` |
| Halving interval | 126,144,000 blocks (~4 years @ 1s) | `HALVING_INTERVAL` |
| SAT/OMNI | 1,000,000,000 (1e9) | `SAT_PER_OMNI` |
| Difficulty retarget | every 2016 blocks | `RETARGET_INTERVAL` |
| DB file | omnibus-chain.dat (v4) | `database.zig::DB_VERSION = 4` |
| Genesis hash | `82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982` | `genesis.zig` |
| Genesis timestamp | 1,743,000,000 (2026-03-26 UTC) | — |
| Network magic | mainnet "OMNI" / testnet "TEST" / devnet "DEVN" / regtest "REGT" | — |
| Shards | 4 | `shard_coordinator.zig` |
| Coinbase maturity | 100 blocks | — |
| Block size limit | 1 MiB | `MAX_BLOCK_SIZE` |
| Block tx limit | 4096 | `MAX_BLOCK_TX` |
| Checkpoint interval | 64 blocks | `CHECKPOINT_INTERVAL` |
| Finality | 6 confirmations (soft) + Casper FFG | `SOFT_FINALITY_CONFIRMS` |
| Fee burn | 50% | `FEE_BURN_PCT` |

## Git Workflow

Every commit must include 9 co-authors:
```
Co-Authored-By: OmniBus AI v1.stable <learn@omnibus.ai>
Co-Authored-By: Google Gemini <gemini-cli-agent@google.com>
Co-Authored-By: DeepSeek AI <noreply@deepseek.com>
Co-Authored-By: Claude 4.5 Haiku (Code) <claude-code@anthropic.com>
Co-Authored-By: Claude 4.5 Haiku <haiku-4.5@anthropic.com>
Co-Authored-By: Claude 4.5 Sonnet <sonnet-4.5@anthropic.com>
Co-Authored-By: Claude 4.5 Opus <opus-4.5@anthropic.com>
Co-Authored-By: Perplexity AI <support@perplexity.ai>
Co-Authored-By: Ollama <hello@ollama.com>
```

## DEX Grid Trading — Reguli fixe (nu se rediscută)

### Arhitectura DEX

OmniBus chain = matching engine + notary. NU stochează fondurile userilor.
Fondurile stau mereu pe chain-ul lor (OMNI pe OmniBus, USDC pe Base/Sepolia, LCX pe Liberty).

**Diferența față de Hyperliquid/Binance:**
- Nu există deposit/withdraw — fondurile merg direct din wallet în HTLC la fill
- Matching on-chain în Zig (nu server centralizat)
- Settlement atomic cross-chain via HTLC
- Grid rulează autonom pe chain — persistă chiar dacă frontentul e offline

### Perechi active (pair_id fix — nu se reordonează niciodată)

| pair_id | Pereche | Maker chain | Taker chains |
|---------|---------|-------------|--------------|
| 0 | OMNI/USDC | OmniBus (htlc_init RPC) | Base Sepolia + Sepolia |
| 2 | LCX/USDC | LCX Liberty | Base Sepolia + Sepolia |
| 3 | ETH/USDC | Sepolia + Base Sepolia | Base Sepolia + Sepolia |
| 5 | OMNI/LCX | OmniBus (htlc_init RPC) | LCX Liberty |
| 6 | OMNI/ETH | OmniBus (htlc_init RPC) | Sepolia + Base Sepolia |

Pair_id 1 (BTC/USDC) și 4 (OMNI/BTC) rezervate pentru viitor.

### HTLC — reguli fixe

- **preimage generat în Zig backend** (nu în frontend/browser)
- preimage stocat în `swap_registry` (memorie + `swap_bindings.bin`)
- preimage NU se trimite niciodată la user — user primește doar `hash_lock`
- HTLC se creează DOAR la momentul fill-ului (nu la plasarea order-ului)
- Order în orderbook = "rezervat" intern, fără fonduri locked încă
- La fill → HTLC automat → preimage revelat automat → settlement atomic

### Grid Trading — reguli fixe

Grid = mecanism automat de market making. Un user setează o dată, chain-ul tranzacționează automat.

**Surse de preț (în ordine de prioritate):**
1. Trade intern — doi useri se întâlnesc în orderbook → preț rezultat
2. Oracle extern — `price_oracle.zig` fetches preț real (Chainlink/Pyth/CoinGecko)

**Flow grid:**
```
grid_create { pair_id, price_low, price_high, levels, total_base, total_quote }
  → Zig generează N buy orders + N sell orders virtuale în range
  → orders vizibile în orderbook ca "open"
  → fondurile NU sunt locked încă

Oracle/trade atinge nivelul unui order
  → fill automat
  → HTLC generat pentru acel fill specific
  → settlement atomic
  → automat plasează order opus (sell filled → plasează buy cu un nivel mai jos)
  → gridul se menține mereu plin

grid_cancel
  → oprește grid
  → fonduri rămân în walletul userului (nu au fost locked niciodată dacă nu e fill)
```

**Capital efficiency:**
- Un singur HTLC activ per fill (nu N HTLC-uri pentru N orders)
- Userul nu plătește fee la plasarea fiecărui order — doar la fill
- Cu 2 useri care pun câte un grid pe același pair → lichiditate imediată

**Fișiere relevante:**
- `core/grid_engine.zig` — engine grid (de implementat)
- `core/matching_engine.zig` — matching existent, grid e wrapper
- `core/price_oracle.zig` — oracle preț existent
- `core/order_swap_link.zig` — HTLC routing + ASSET_CHAINS
- `core/rpc_server.zig` — RPC: `grid_create`, `grid_list`, `grid_cancel`, `grid_status`

**RPC-uri grid:**
```
grid_create  { pair_id, price_low, price_high, levels, total_base, total_quote, owner }
grid_list    { owner? }   → array grid-uri active cu status
grid_cancel  { grid_id }  → oprește grid
grid_status  { grid_id }  → fills făcute, profit, orders active
```

### Comparație DEX-uri

| | Hyperliquid | Uniswap | OmniBus DEX |
|--|--|--|--|
| Custody | Smart contract | Smart contract | User wallet mereu |
| Deposit | DA | DA | NU |
| Matching | L1 propriu off-chain | AMM (x*y=k) | OmniBus chain Zig |
| Grid | Off-chain, dispare la crash | NU există | On-chain, persistent |
| Cross-chain | NU (bridge separat) | NU | DA nativ (HTLC) |
| Preț | Order book | Curve matematică | Order book + Oracle |

## Ecosystem Context

This repo is one of 8+ repos in `C:\Kits work\limaje de programare\` — the OmniBus financial platform ecosystem. See the parent `CLAUDE.md` for cross-repo architecture. Key siblings: OmniBus (bare-metal OS), Zig-toolz-Assembly (HFT), TorNetworkExchange (DEX), OmnibusSidebar (desktop wallet).
