# 6. Mining & Consensus

> OmniBus vs Bitcoin — Category 6/10
> Generated: 2026-03-31 16:50

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 101 | Proof of Work (PoW) | Y | Y | consensus.zig | SHA256d PoW |
| 102 | Nonce Search | Y | Y | consensus.zig | Brute-force mining |
| 103 | Difficulty Target | Y | Y | consensus.zig | Dynamic target |
| 104 | Difficulty Adjustment | Y | Y | consensus.zig | Every 2016 blocks |
| 105 | Block Reward | Y | Y | consensus.zig | 50 OMNI start |
| 106 | Halving Schedule | Y | Y | consensus.zig | Every 210K blocks |
| 107 | Coinbase TX Creation | Y | Y | block.zig | First TX in block |
| 108 | Mining Pool Protocol | Y | Y | mining_pool.zig | Pool coordination |
| 109 | Stratum Client | Y | N | - | miner-client.js (Node.js) |
| 110 | Chain Reorganization | Y | Y | blockchain.zig | Fork resolution |
| 111 | Light Miner | N | + | light_miner.zig | Low-resource mining [EXTRA] |
| 112 | Sub-block Engine | N | + | sub_block.zig | 10x faster finality [EXTRA] |
| 113 | Casper FFG Finality | N | + | finality.zig | PoS finality layer [EXTRA] |
| 114 | Staking / Validators | N | + | staking.zig | Validator system [EXTRA] |
| 115 | Governance Voting | N | + | governance.zig | On-chain governance [EXTRA] |

---

**BTC has: 10 items**
**OmniBus: 14 implemented, 0 partial, 1 missing, 5 extras**
**Score: 140%** (14/10 BTC features + 5 unique extras)

### Missing (TODO):
- [ ] Stratum Client — miner-client.js (Node.js)

### Extras (OmniBus-only):
- Light Miner — Low-resource mining [EXTRA]
- Sub-block Engine — 10x faster finality [EXTRA]
- Casper FFG Finality — PoS finality layer [EXTRA]
- Staking / Validators — Validator system [EXTRA]
- Governance Voting — On-chain governance [EXTRA]

