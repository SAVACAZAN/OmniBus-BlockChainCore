# OmniBus-BlockChainCore

**Post-quantum blockchain — Bitcoin-compatible + 4 NIST FIPS PQ schemes live on testnet**
**Versiune:** 0.3.0-dev · **Limbă:** Zig 0.15.2 + Node.js + TypeScript/React
**Live:** https://omnibusblockchain.cc · **GitHub:** https://github.com/SAVACAZAN/OmniBus-BlockChainCore

---

## TL;DR

OmniBus is a Bitcoin-compatible blockchain with **real post-quantum signatures** verified by `liboqs` (NIST FIPS 203/204/205/206). All 4 PQ algorithms — ML-DSA-87, Falcon-512, Dilithium-5, SLH-DSA-256s — are live on testnet, signed in-browser via `@noble/post-quantum`, verified server-side by `liboqs`. **20/20 PQ TX matrix passing on VPS testnet** as of 2026-05-06.

> **First read:** `STATUS/README.md` — entry point with up-to-date infrastructure, status, and inventory. The auto-generated docs in `STATUS/` are the source of truth for current state.

---

## Quick start

```bash
# Build (requires Zig 0.15.2 + liboqs)
zig build -Doptimize=ReleaseSafe -Doqs=true

# Build without PQ (faster local iteration, disables liboqs)
zig build -Doqs=false

# Run a seed node
./zig-out/bin/omnibus-node --mode seed --node-id node-1 --port 9000

# Run a miner
./zig-out/bin/omnibus-node --mode miner --node-id miner-1 \
  --seed-host 127.0.0.1 --seed-port 9000

# Tests
zig build test           # all tests (no liboqs)
zig build test-crypto    # secp256k1, BIP32, ripemd160, schnorr, multisig, BLS
zig build test-chain     # block, blockchain, mempool, consensus, finality
zig build test-net       # RPC, P2P, sync, network
zig build test-pq        # PQ pure-Zig stubs (no liboqs)
zig build test-wallet    # wallet (requires liboqs)
```

**liboqs prerequisite** (Windows: MinGW; Linux: gcc):
```bash
git clone https://github.com/open-quantum-safe/liboqs liboqs-src
cd liboqs-src && mkdir build && cd build
cmake -DOQS_USE_OPENSSL=OFF ..   # MinGW: add -G "MinGW Makefiles"
make -j4                          # MinGW: mingw32-make -j4
```
Build expects `liboqs.a` at:
- Linux: `/root/liboqs-src/build/lib/liboqs.a`
- Windows: `C:/Kits work/limaje de programare/1_CORE/liboqs-src/build/lib/liboqs.a`

---

## Command Line Interface

OmniBus ships with `omnibus-cli` — a pure-stdlib Zig CLI that gives terminal /
scripting access to the same chain-state views the React frontend renders
(balance, stake, reputation, daily breakdown, validator list, sanity check).
Source: [`core/cli_audit.zig`](core/cli_audit.zig). Build target produced by
`zig build install` → `zig-out/bin/omnibus-cli(.exe)`.

```sh
# Local node
omnibus-cli health
omnibus-cli balance ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0
omnibus-cli stake   ob1q...zp0
omnibus-cli daily   ob1q...zp0 30
omnibus-cli verify  ob1q...zp0          # exit 1 on chain-vs-history mismatch

# Public testnet (HTTPS via curl)
omnibus-cli --remote --chain testnet health
omnibus-cli --remote --chain testnet stakers 20

# JSON output for scripting / jq pipelines
omnibus-cli --json daily ob1q...zp0 7 \
  | jq '.result.transactions[] | select(.kind=="coinbase")'
```

Subcommands: `balance`, `stake`, `reputation`, `daily`, `validators`,
`stakers`, `health`, `history`, `verify`. The CLI is read-only — signed flows
(staking, swap, name register, agent register) go through aweb3 or raw
RPC `curl`. See:

- [`docs/CLI_REFERENCE.md`](docs/CLI_REFERENCE.md) — full reference (flags, RPCs, JSON shapes)
- [`docs/CLI_TUTORIAL.md`](docs/CLI_TUTORIAL.md) — step-by-step tutorials în română
- [`docs/CLI_COOKBOOK.md`](docs/CLI_COOKBOOK.md) — copy-paste recipes (CSV export, watchers, alerts)
- [`docs/cli/omnibus-cli.1`](docs/cli/omnibus-cli.1) — Linux man page (nroff)
- [`scripts/install-cli.sh`](scripts/install-cli.sh) — one-shot installer (binary + man + completion)
- [`scripts/completion/`](scripts/completion/) — bash, zsh, fish completions

---

## Address taxonomy (canonical — `STATUS/MASTER_RULES_PQ_OMNI.md`)

OmniBus uses two parallel address families:

### Transferable (used in TXs)

| Prefix | Scheme | NIST | Code | BIP-44 path |
|---|---|---|---|---|
| `ob1q…` | secp256k1 ECDSA (Bech32) | — | 0 | `m/44'/777'/0'/0/N` |
| `obk1_…` | ML-DSA-87 | FIPS 204 | 5 | `m/44'/777'/5'/0/0` |
| `obf5_…` | Falcon-512 | FIPS 206 | 6 | `m/44'/777'/6'/0/0` |
| `obs3_…` | Dilithium-5 (alias) | FIPS 204 | 7 | `m/44'/777'/7'/0/0` |
| `obd5_…` | SLH-DSA-256s | FIPS 205 | 8 | `m/44'/777'/8'/0/0` |

### Soulbound (identity reputation, non-transferable)

| Prefix | Scheme | Concept | Code |
|---|---|---|---|
| `ob_k1_…` | `love_dilithium` | OMNI_LOVE | 1 |
| `ob_f5_…` | `food_falcon` | OMNI_FOOD | 2 |
| `ob_d5_…` | `rent_slh_dsa` | OMNI_RENT | 3 |
| `ob_s3_…` | `vacation_kem` (KEM, no signing) | OMNI_VACATION | 4 |

**Key distinction:** transferable prefixes have NO leading underscore (`obk1_`); soulbound do (`ob_k1_`). Don't conflate them — see `STATUS/MASTER_RULES_PQ_OMNI.md` for derivation algorithm and anti-patterns.

The chain (`core/transaction.zig:180-201` + `core/isolated_wallet.zig:64-67`) is the authority on this mapping. UI, scripts, and tests align to it. Run `python tools/audit-pq-conventions.py` after multi-agent sessions — drift must be 0.

---

## Repo layout

```
BlockChainCore/
├── core/                       Zig blockchain modules (~85 files)
│   ├── main.zig                Entry: vault, db, genesis, wallet, mempool, P2P, RPC, mining
│   ├── blockchain.zig          Chain state, mempool, validation, nonce, balance tracking
│   ├── block.zig               Block struct, hash, validation
│   ├── transaction.zig         TX sign/verify, prefix→scheme map, calculateHash (canon)
│   ├── isolated_wallet.zig     PQ Scheme enum, prefix(), verifySignature dispatcher
│   ├── pq_crypto.zig           liboqs FFI: ML-DSA-87, Falcon-512, SLH-DSA, ML-KEM-768
│   ├── secp256k1.zig           ECDSA pure Zig (no external deps)
│   ├── bip32_wallet.zig        BIP-32/39 HD wallet
│   ├── ripemd160.zig           RIPEMD-160 pure Zig (80 rounds)
│   ├── crypto.zig              SHA-256, SHA-256d, HMAC
│   ├── rpc_server.zig          JSON-RPC 2.0 :8332/:18332/:28332 (mainnet/testnet/regtest)
│   ├── ws_server.zig           WebSocket events :8334
│   ├── consensus.zig           PoW + difficulty adjustment
│   ├── sub_block.zig           10×0.1s sub-block engine → KeyBlock assembly
│   ├── finality.zig            Casper FFG checkpoints
│   ├── mempool.zig             Mempool with FIFO + size/time limits
│   ├── p2p.zig                 TCP P2P transport
│   ├── sync.zig                Block sync protocol
│   ├── shard_coordinator.zig   4-shard architecture
│   ├── escrow.zig              Escrow contracts
│   ├── faucet.zig              Faucet TX type (testnet)
│   ├── governance_onchain.zig  On-chain voting
│   ├── label.zig               Address labels
│   ├── notarize.zig            Document notarization
│   ├── poap.zig                Proof of attendance
│   ├── social_graph.zig        Follow / social relations
│   ├── subscription.zig        Recurring payments
│   └── ... (storage, archive, state_trie, peer_scoring, lightning, htlc, psbt, …)
│
├── frontend/                   React + TypeScript + Vite
│   └── src/api/
│       ├── pq-sign.ts          @noble/post-quantum signing + canonical buildTxHash
│       ├── wallet-keystore.ts  BIP-44 derivation (canon: accounts 5/6/7/8)
│       └── rpc-client.ts       JSON-RPC client
│
├── tools/                      Audit + tooling (Python stdlib only)
│   ├── audit-pq-conventions.py  Drift detector for PQ prefix/scheme/BIP-44
│   ├── inventory-md.py          Classify .md files KEEP/ARCHIVE/REVIEW
│   ├── consolidate-status.py    Extract TODO/DONE/BLOCKED into STATUS.md
│   ├── bootstrap-context.py     Auto-generate INFRASTRUCTURE.md from git/ssh/VPS
│   └── TESTING/
│       └── stress-pq-matrix.mjs  4×5 PQ→* live test, runs against testnet
│
├── STATUS/                     Auto-generated single source of truth
│   ├── README.md               Reading order for new sessions / agents
│   ├── INFRASTRUCTURE.md       VPS, SSH, ports, branches, build commands
│   ├── STATUS.md               Live TODO/DONE/BLOCKED across the codebase
│   ├── INVENTORY.md            Every .md classified KEEP/ARCHIVE/REVIEW
│   ├── MASTER_RULES_PQ_OMNI.md Hand-edited canon for PQ schemes
│   └── archiveREADME/          Old .md files (non-destructive moves) + INDEX.md
│
└── build.zig                   Zig 0.15.2 build with -Doqs=true|false toggle
```

---

## RPC API — JSON-RPC 2.0

**Ports:**
- Mainnet: `:8332`
- Testnet: `:18332` (public via https://omnibusblockchain.cc:8443/api-testnet)
- Regtest: `:28332`
- WebSocket events: `:8334` / `:18334` / `:28334`

```bash
# Status
curl -X POST http://localhost:18332 -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getstatus","params":[]}'

# Balance (any address — ECDSA or any PQ prefix)
curl -X POST http://localhost:18332 -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getbalance","params":["obk1_Ysa..."]}'

# Send PQ TX (signed externally with @noble/post-quantum)
curl -X POST http://localhost:18332 -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"pq_send","params":[{
    "from":"obk1_...","to":"ob1q...","amount":1000,"fee":1,
    "scheme":"pq_omni_ml_dsa","signature":"<hex>","public_key":"<hex>",
    "id":12345,"timestamp":1778063000,"nonce":0
  }]}'
```

| Method | Description |
|---|---|
| `getblockcount` | Chain height |
| `getbalance` | `{address, balance, balanceOMNI, confirmed, unconfirmed, txCount}` |
| `getlatestblock` | Latest block summary |
| `getmempoolsize` | Pending TX count |
| `getstatus` | `{status, blockCount, mempoolSize, address, balance}` |
| `getnonce` | `{nonce, chainNonce, pendingCount}` (next nonce + mempool pending) |
| `sendtransaction` | Build + sign ECDSA TX with node's wallet (node-held keys) |
| `pq_send` | Submit externally-signed PQ TX (any of 4 schemes) |
| `pq_verify_test` | Debug: verify a sig directly without TX wrapper (since 2026-05-06) |
| `getaddressbalance` | Detailed balance for an address |
| `getfaucetstatus` | Faucet config (testnet) |
| `claimfaucet` | Get testnet OMNI from faucet |

`pq_verify_test` schema:
```json
{
  "scheme": "ml_dsa_87" | "falcon_512" | "dilithium_5" | "slh_dsa_256s",
  "public_key": "<hex>",
  "message":    "<hex>",
  "signature":  "<hex>"
}
→ {"verified": true|false, "scheme":"...", "msg_len":N, "pk_len":N, "sig_len":N}
```

---

## Chain parameters

| Parameter | Value |
|---|---|
| Block time | 10s (10×0.1s sub-blocks → 1 KeyBlock) |
| Difficulty | adjustable, starts at 1 zero nibble |
| Block reward | 50 OMNI (halves every 210,000 blocks) |
| 1 OMNI | 1,000,000,000 SAT (10⁹) |
| Max supply | 21,000,000 OMNI |
| Signature schemes | ECDSA (secp256k1) + 4× PQ via liboqs |
| Shards | 4 (sharded mining, cross-shard receipts) |
| DB file | `data/<chain>/chain.dat` |
| Chains | mainnet, testnet (with faucet), regtest |

---

## Frontend (React + TypeScript)

```bash
cd frontend
npm install
npm run dev      # Vite dev server (default :5173)
npm run build    # production build → dist/
```

Connects to RPC at `:8332/:18332/:28332` and WebSocket at `:8334+` for live updates.

PQ signing happens in-browser via `@noble/post-quantum` (no WASM, pure JS FIPS 204/205/206). Adresses are derived from the seed phrase using BIP-44 paths per scheme; signatures are submitted to chain via `pq_send` and verified server-side by `liboqs`.

---

## Live testnet

- **Public RPC:** https://omnibusblockchain.cc:8443/api-testnet
- **Frontend:** https://omnibusblockchain.cc:8443
- **Status:** Active, mining, faucet enabled
- **Verified:** 4×5 = 20/20 PQ→* TX matrix passing (2026-05-06) — see `tools/TESTING/stress-pq-matrix.mjs`

Get testnet OMNI:
```bash
curl -X POST https://omnibusblockchain.cc:8443/api-testnet \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"claimfaucet","params":["ob1q...your_address..."]}'
```

---

## Status snapshot (2026-05-06)

| Component | Status |
|---|---|
| **Real PQ crypto** (4 schemes via liboqs, NIST-conformant) | ✅ Live |
| **noble↔liboqs interop** (browser sign → server verify) | ✅ Verified end-to-end |
| **PQ TX matrix** | ✅ 20/20 on testnet VPS |
| **secp256k1 ECDSA** + Bech32 | ✅ Bitcoin-compatible |
| **BIP-32/39/44** HD wallet | ✅ |
| **JSON-RPC 2.0** + WebSocket | ✅ |
| **Mining + sub-blocks + Casper FFG** | ✅ |
| **4 shards** + cross-shard receipts | ✅ |
| **8 typed TX modules** (escrow, faucet, notarize, poap, governance, label, social_graph, subscription) | ✅ |
| **Storage + persistence** (chain.dat, chainstate snapshots) | ✅ |
| **P2P TCP transport** | ✅ |
| **liboqs MinGW (Windows) + glibc (Linux VPS)** | ✅ |
| **Audit tooling** (`tools/audit-pq-conventions.py` — drift = 0) | ✅ |
| **STATUS folder + auto-docs** | ✅ |

For live state run:
```bash
python tools/bootstrap-context.py --query-vps omnibus-vps  # snapshot of VPS state
python tools/consolidate-status.py                          # all TODO/BLOCKED in repo
python tools/inventory-md.py                                # MD file classification
```

---

## Multi-chain support

In addition to native `ob1q…` addresses, the wallet derives 19 chains from the same mnemonic:

OMNI · BTC (4 types: P2PKH, P2SH, P2WPKH, P2TR) · ETH · SOL · ADA · DOT · EGLD · ATOM · XLM · XRP · BNB · OP · LTC · DOGE · BCH · MATIC · AVAX

Each chain uses its standard BIP-44 coin_type. PQ-OMNI uses coin_type 777 with per-scheme accounts 5..8.

---

## Mining pool (Node.js)

```bash
node create-wallet.js batch 10        # generate 10 miner wallets
bash start-genesis.sh                 # start pool + 10 miners
bash add-miners-staggered.sh 100 10 5 # add 100 miners, batch 10, delay 5s
```

Pool features:
- Dynamic `registerminer` (no hardcoded miner list)
- 30s keepalive timeout, auto-remove inactive
- Equal reward distribution to active miners
- Persistent `balances.json`

---

## SuperVault integration

Mnemonic resolution priority on startup:
1. **Named Pipe** `\\.\pipe\OmnibusVault` (if `vault_service.exe` runs)
2. **Env var** `OMNIBUS_MNEMONIC`
3. **Dev default** (`abandon` × 11 + `about` — testnet only, public)

```bash
export OMNIBUS_MNEMONIC="word1 word2 ... word12"
./zig-out/bin/omnibus-node --mode seed
```

---

## VPS deployment

VPS testnet runs at `38.143.19.97` (alias `omnibus-vps` in `~/.ssh/config`):
- 3 systemd services: `omnibus-mainnet`, `omnibus-testnet` (with faucet), `omnibus-regtest`
- Repo at `/root/omnibus-blockchain/`
- Gitea (Docker container `gitea`) at `:3000` for the private mirror

Deploy via git bundle (no token needed for transport):
```bash
git bundle create /tmp/deploy.bundle <last-vps-commit>..HEAD
scp /tmp/deploy.bundle omnibus-vps:/tmp/
ssh omnibus-vps 'cd /root/omnibus-blockchain && \
  git fetch /tmp/deploy.bundle <branch>:<branch>-NEW && \
  git reset --hard <branch>-NEW && \
  rm -rf .zig-cache zig-out && \
  zig build -Doptimize=ReleaseSafe -Doqs=true && \
  systemctl restart omnibus-testnet'
```

Token regeneration for VPS Gitea (when push gives 403):
```bash
ssh omnibus-vps 'docker exec gitea su git -c "gitea admin user generate-access-token \
  --username cazan --token-name claude-deploy-$(date +%F) --scopes write:repository"'
```

Full operational runbook in `STATUS/INFRASTRUCTURE.md`.

---

## Documentation

- `CLAUDE.md` — coding conventions and architecture for AI assistants
- `STATUS/README.md` — reading order for any new session/agent
- `STATUS/MASTER_RULES_PQ_OMNI.md` — hand-edited canon for PQ schemes
- `STATUS/INFRASTRUCTURE.md` — auto-generated VPS/SSH/git/build snapshot
- `STATUS/STATUS.md` — auto-generated TODO/DONE/BLOCKED roundup
- `API_REFERENCE.md` — full RPC reference
- `MODULES_REFERENCE.md` — Zig module catalog
- `wiki-omnibus/` and `wiki-kimi-omnibus/` — long-form architecture docs

---

## Companion projects (ecosystem)

This repo is one of 8+ in the OmniBus financial platform ecosystem at
`C:\Kits work\limaje de programare\`:
- **OmniBus** (`1_CORE/OmniBus`) — bare-metal OS for HFT
- **OmniBus-Connect** (`2_SDK/Connect`) — Python exchange SDK
- **aweb3** (`3_DESKTOP_APPS/aweb3`) — Tauri DeFi app
- **OmnibusSidebar** (`3_DESKTOP_APPS/sidebar-cpp`) — C++ desktop wallet (talks to this node)
- **zig-hft, tor-network-exchange** — exchange implementations

See parent `CLAUDE.md` for cross-repo architecture.

---

## License

Proprietary — see project root.
