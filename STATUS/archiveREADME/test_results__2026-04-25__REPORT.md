# BlockChainCore — Test Session Report

**Date:** 2026-04-25
**Duration:** ~30 min
**Build version:** v0.3.1 (post-fixes)

---

## Summary

| Test | Result | Notes |
|------|--------|-------|
| 🟢 Build (`zig build -Doqs=false`) | PASS | Exit 0, zero warnings |
| 🟢 Unit tests (8 groups) | **8/8 PASS** | test, test-crypto, test-chain, test-net, test-shard, test-storage, test-light, test-pq |
| 🟢 RPC live (5/12 methods) | PARTIAL | Core methods OK, missing standard Bitcoin RPCs |
| 🟢 Mainnet boot | PASS | Loaded 140 blocks from `omnibus-chain.dat` |
| 🟢 P2P sync (seed + miner) | PASS | Block #156 announced + relayed to 1 peer |
| 🔴 → 🟢 DB separation per chain | FIXED | Initial: not wired in main.zig. After fix: 3 DBs isolated correctly |
| 🟢 Chain selection (`--mainnet/--testnet/--regtest`) | FIXED | Initial: ignored, defaulted to mainnet. After fix: picks correct ChainConfig |

---

## Unit Tests (8/8 PASS)

```
test:         PASS (1m 12s)
test-crypto:  PASS (9s)
test-chain:   PASS (43s)
test-net:     PASS (11s)
test-shard:   PASS (7s)
test-storage: PASS (1s)
test-light:   PASS (5s)
test-pq:      PASS (~immediate)
```

Files: `01_unit_tests/{group}.log` for each.

---

## RPC Live Tests

Seed node @ `http://127.0.0.1:8332` while running with mainnet DB (141 blocks total).

### ✅ Working (5)

| Method | Response |
|--------|----------|
| `getblockcount` | `141` |
| `getbalance` | Full wallet info: address, balance, UTXOs, txCount |
| `getmempoolinfo` | `{size: 0, bytes: 0}` |
| `getblockchaininfo` | `{blocks: 141, difficulty: 4, chain: "omnibus-mainnet", version: "0.3.0"}` |
| `getnetworkinfo` | Full network details (chain, blockHeight, peerCount, etc.) |

### ❌ Not implemented (7)

- `getbestblockhash`
- `getdifficulty`
- `getblockhash(N)`
- `getconnectioncount`
- `getmininginfo`
- `getpeerinfo`
- `getblock(hash)`

**Action:** consider adding these for Bitcoin RPC compatibility.

---

## P2P Sync Test (2 nodes)

**Setup:**
- Seed: `--mode seed --port 9000 --primary` (loaded mainnet, 141 blocks)
- Miner: `--mode miner --port 9001 --seed-host 127.0.0.1 --seed-port 9000`

**Result:** P2P working — blocks announced + gossip relay confirmed:

```
[REWARD] Miner ob1qw6zhsqg29aht +8333333 SAT (0.01 OMNI) @ block 155
[P2P] Block #155 anuntat la 1 peeri
[GOSSIP] Block #155 relayed to 1 peers
[META] Block #15 finalized | shards=1 | tx=0 | cross_receipts=0
```

**⚠️ Side effect:** miner used same DB as seed (legacy `omnibus-chain.dat`) and added 16 blocks (140 → 156). DB was restored after test from snapshot `omnibus-chain.dat.backup-20260425-1230`. Tainted version saved as `omnibus-chain.dat.test-tainted-1237`.

---

## Critical Issues Found & Fixed

### Issue 1 (FIXED): DB path not wired per chain

**Symptom:** `--testnet` and `--regtest` flags both wrote to `omnibus-chain.dat` (mainnet DB).

**Root cause:** `main.zig` had `const DB_PATH = "omnibus-chain.dat"` hardcoded. Agent A3 (initial round) created `dbPathForChain()` in `database.zig` but the wire-up in main.zig was never done.

**Fix:** Replaced `DB_PATH` constant with runtime `db_path` calculated per chain:
- Mainnet → uses `omnibus-chain.dat` if present (legacy back-compat), else `data/mainnet/chain.dat`
- Testnet → always `data/testnet/chain.dat`
- Regtest → always `data/regtest/chain.dat`

8 references in main.zig updated.

### Issue 2 (FIXED): Chain selection ignored CLI flag

**Symptom:** `--regtest` showed `Network: omnibus-mainnet` in banner.

**Root cause:** `main.zig` line 268 used `cli.parseArgs(args)` (legacy, returns NodeConfig without chain_mode) instead of `cli.parseArgsFull(args)` (returns ParsedArgs with chain_mode). Then selected chain via `if (config.testnet) testnet else mainnet` boolean.

**Fix:**
```zig
const parsed = cli.parseArgsFull(args) catch |err| { ... };
const config = parsed.node;  // alias for back-compat with existing code

const net_cfg: ChainConfig = switch (parsed.chain_mode) {
    .mainnet => ChainConfig.mainnet(),
    .testnet => ChainConfig.testnet(),
    .regtest => ChainConfig.regtest(),
};
```

---

## Final Verification (All 3 chains)

| Command | Network | Chain ID | DB Path |
|---------|---------|----------|---------|
| `omnibus-node --mainnet` | omnibus-mainnet | 1 | `omnibus-chain.dat` (legacy) ✅ |
| `omnibus-node --testnet` | omnibus-testnet | 2 | `data/testnet/chain.dat` ✅ |
| `omnibus-node --regtest` | omnibus-regtest | 4 | `data/regtest/chain.dat` ✅ |

`data/` directory tree auto-created with subfolders per chain.

---

## DB Backup Trail

| File | Size | Description |
|------|------|-------------|
| `omnibus-chain.dat` | 29910 B | Restored — original 140 blocks |
| `omnibus-chain.dat.backup-20260425-1230` | 29910 B | Pre-test snapshot |
| `omnibus-chain.dat.bak` | 29860 B | Auto-created backup by node |
| `omnibus-chain.dat.test-tainted-1237` | 38033 B | Tainted version with 16 test-mined blocks (kept for reference) |
| `test_results/2026-04-25/04_node_logs/omnibus-chain.dat.pretest-1235` | 29860 B | Backup before test session |

---

## Folder Structure for Test Results

```
test_results/
├── 2026-04-25/
│   ├── 01_unit_tests/        # zig build test-* outputs
│   │   ├── _summary.txt
│   │   ├── run.log
│   │   ├── test.log
│   │   ├── test-crypto.log
│   │   └── ... (8 logs)
│   ├── 02_rpc_tests/         # curl JSON-RPC results
│   │   ├── _results.txt
│   │   └── db_selection.log
│   ├── 03_p2p_sync/          # (empty — output captured in 04_node_logs)
│   ├── 04_node_logs/         # raw node stdout/stderr
│   │   └── omnibus-chain.dat.pretest-1235
│   └── REPORT.md             # this file
└── latest/
    └── _pointer.txt          # → "2026-04-25"
```

---

## What's Next (P2-P4)

### P2 — Quick wins (10 min)

- [ ] Test transaction send (regtest, instant blocks)
- [ ] Add missing standard RPC methods (`getblockhash`, `getblock`, `getbestblockhash`)
- [ ] Test multi-peer P2P (3+ nodes)

### P3 — Wallet operations (15 min)

- [ ] Custom mnemonic via `--mnemonic` flag
- [ ] Test cross-chain wallet derivation (5 PQ domains)
- [ ] Test mempool propagation

### P4 — Advanced (1h+)

- [ ] Bridge wire-up (OmniBus chain ↔ Sepolia bridge from aweb3)
- [ ] PQ wallet build with `-Doqs=true` (requires liboqs MinGW)
- [ ] Mining pool functional test
- [ ] Lightning Network channel open/close

---

## Co-Authors (this session)

- 5 parallel agents (chain wiring round 1) — 205K tokens total, ~7 min
- 3 parallel agents (cleanup fixes) — 144K tokens, ~3 min
- 1 agent (DB path wiring fix) — 56K tokens, 70s
- Manual fixes by Claude Code main session: chain_mode wire-up, devnet enum issue
