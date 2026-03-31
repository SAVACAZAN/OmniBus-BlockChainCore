# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

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

| Parameter | Value |
|-----------|-------|
| Block time | 10s (10 × 0.1s sub-blocks) |
| RPC port | 8332 (HTTP) |
| WebSocket port | 8334 |
| P2P port | 9000+ (configurable) |
| Max supply | 21M OMNI |
| Block reward | 50 OMNI (halves every 210k blocks) |
| SAT/OMNI | 1,000,000,000 (1e9) |
| DB file | omnibus-chain.dat |
| Shards | 4 |

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

## Ecosystem Context

This repo is one of 8+ repos in `C:\Kits work\limaje de programare\` — the OmniBus financial platform ecosystem. See the parent `CLAUDE.md` for cross-repo architecture. Key siblings: OmniBus (bare-metal OS), Zig-toolz-Assembly (HFT), TorNetworkExchange (DEX), OmnibusSidebar (desktop wallet).
