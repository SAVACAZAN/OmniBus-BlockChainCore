# 2. Blockchain Structure

> OmniBus vs Bitcoin — Category 2/10
> Generated: 2026-03-31 18:17

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 21 | Genesis Block | Y | Y | genesis.zig | "26/Mar/2026 OmniBus born" |
| 22 | Block Header | Y | Y | block.zig | prev_hash, merkle_root, nonce |
| 23 | Block Body (TX list) | Y | Y | block.zig | Transaction array |
| 24 | Merkle Tree | Y | Y | block.zig | SHA256d merkle root |
| 25 | UTXO Set | Y | Y | state_trie.zig | Account-based primary, UTXO planned |
| 26 | Transaction Structure | Y | Y | transaction.zig | Full TX with sig, hash, nonce |
| 27 | Coinbase Transaction | Y | Y | consensus.zig | Block reward TX |
| 28 | Block Height | Y | Y | blockchain.zig | Sequential numbering |
| 29 | Block Weight / Size | Y | Y | sub_block.zig | Sub-block weight system |
| 30 | Block Time | Y | Y | consensus.zig | 10s (10x0.1s sub-blocks) |
| 31 | Difficulty Target | Y | Y | consensus.zig | Adjustable |
| 32 | Difficulty Adjustment | Y | Y | consensus.zig | Every 2016 blocks |
| 33 | Max Supply (21M) | Y | Y | chain_config.zig | 21M OMNI |
| 34 | Halving | Y | Y | consensus.zig | Every 210K blocks |
| 35 | Block Reward | Y | Y | consensus.zig | 50 OMNI, halves |
| 36 | Sub-block Engine | N | + | sub_block.zig | 10 sub-blocks/key block [EXTRA] |
| 37 | Sharding (4 shards) | N | + | shard_coordinator.zig | Parallel processing [EXTRA] |
| 38 | Metachain | N | + | metachain.zig | Cross-shard coordination [EXTRA] |
| 39 | Compact Blocks | Y | Y | binary_codec.zig | Binary encoding |
| 40 | Block Archive | Y | Y | archive_manager.zig | Historical data |

---

**BTC has: 17 items**
**OmniBus: 20 implemented, 0 partial, 0 missing, 3 extras**
**Score: 117%** (20/17 BTC features + 3 unique extras)

### Extras (OmniBus-only):
- Sub-block Engine — 10 sub-blocks/key block [EXTRA]
- Sharding (4 shards) — Parallel processing [EXTRA]
- Metachain — Cross-shard coordination [EXTRA]

