# 8. Storage & Database

> OmniBus vs Bitcoin — Category 8/10
> Generated: 2026-03-31 16:50

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 141 | Block Storage (files) | Y | Y | database.zig | omnibus-chain.dat |
| 142 | Binary Codec | Y | Y | binary_codec.zig | Compact encoding |
| 143 | State Trie | N | + | state_trie.zig | Ethereum-style state [EXTRA] |
| 144 | Archive Manager | Y | Y | archive_manager.zig | Old block management |
| 145 | Pruning Configuration | Y | Y | prune_config.zig | Space-saving |
| 146 | Witness Storage | Y | N | witness.zig | Segregated witness data |
| 147 | Compact Transactions | Y | N | compact_tx.zig | Compressed TXs |
| 148 | UTXO Index | Y | Y | state_trie.zig | Account-based (partial) |
| 149 | Blockchain V2 Engine | N | + | blockchain_v2.zig | Next-gen arch [EXTRA] |
| 150 | Shard Config | N | + | shard_config.zig | 4-shard storage [EXTRA] |

---

**BTC has: 7 items**
**OmniBus: 8 implemented, 0 partial, 2 missing, 3 extras**
**Score: 114%** (8/7 BTC features + 3 unique extras)

### Missing (TODO):
- [ ] Witness Storage — Segregated witness data
- [ ] Compact Transactions — Compressed TXs

### Extras (OmniBus-only):
- State Trie — Ethereum-style state [EXTRA]
- Blockchain V2 Engine — Next-gen arch [EXTRA]
- Shard Config — 4-shard storage [EXTRA]

