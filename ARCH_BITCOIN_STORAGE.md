# Bitcoin-style Storage Refactor — Architecture Spec

**Status:** Design only. Implementation tracked in branch `arch/leveldb-storage`.
**Trigger:** 2026-04-28 testnet data loss — 51 of 54 faucet recipients
lost their balances at restart because state lived only in `bc.balances`
HashMap, not in chain TXs, and the in-mining-loop save had been removed
to recover p99 latency.

This document specifies how OmniBus should store its chain on disk,
modelled on Bitcoin Core's design and adapted for our higher block rate
(60/min vs Bitcoin's 0.16/min).

## What Bitcoin actually does

Three independent storage layers, each with a single job:

```
~/.bitcoin/
├── blocks/
│   ├── blk00000.dat        ← raw block data, append-only, 128 MB chunks
│   ├── blk00001.dat
│   ├── blk00002.dat
│   ├── rev00000.dat        ← undo data per block (for reorgs)
│   ├── rev00001.dat
│   └── index/              ← LevelDB
│       ├── 000003.log
│       ├── CURRENT
│       └── MANIFEST-000002
│           # block_hash → (file_no, offset, height, status, ...)
├── chainstate/             ← LevelDB
│   ├── 000123.log
│   ├── CURRENT
│   └── MANIFEST-000122
│       # UTXO set: outpoint → (amount, script, height, coinbase_flag)
├── mempool.dat             ← serialised mempool, persisted at shutdown
├── peers.dat               ← peer addresses for next startup
└── wallet.dat              ← wallet (legacy or BDB-only setups)
```

Properties:

- **`blocks/blkNNNNN.dat`** — append-only. Once a block is written, the
  bytes never change. New blocks always extend the most recent file
  until it hits ~128 MB, then a new file starts. Zero rewrites means
  zero opportunity for corruption from interrupted writes.

- **`blocks/index/`** — small LevelDB. Maps every known block hash to
  `(file_number, byte_offset, height, validity_status)`. Allows
  `getblock(hash)` in O(log n) without scanning files.

- **`chainstate/`** — the live state. UTXO set (every unspent output
  currently in existence). Updated incrementally at every block: add
  the new TX outputs, remove the consumed inputs. LevelDB's WAL
  (write-ahead log) makes this crash-safe — at restart the last
  partial batch is rolled back from the log.

- **`rev00000.dat`** — undo data. For every block, we record how to
  reverse its effect on the UTXO set. Needed only for reorgs.

- **`mempool.dat`** — the unconfirmed-TX pool. Serialised at graceful
  shutdown, replayed at startup so the mempool isn't empty for the
  first 10 minutes.

Why this is robust:

1. **Block files are append-only.** A crash mid-write at most leaves a
   torn last record, detected by length+CRC at the next read; the
   block in question is rejected and re-fetched from peers.

2. **Chainstate is always derivable from blocks.** If chainstate is
   corrupt or missing, `bitcoind -reindex-chainstate` rebuilds it from
   the block files. Slow (hours on mainnet) but always possible.

3. **No single "kitchen-sink" file.** Each layer has one responsibility.
   A bug in mempool persistence can't poison chainstate; a bug in
   chainstate writes can't corrupt blocks.

## What we have today (the broken design)

```
data/<chain>/
├── chain.dat              ← monolithic single file
├── chain.dat.bak          ← copy of last good version
├── orders.jsonl           ← exchange orders journal
├── faucet-claims.json     ← faucet rate-limit log
├── exchange-users.jsonl   ← exchange auth journal
└── dns_registry.bin       ← .omnibus name registry
```

The single `chain.dat` carries:

- header (magic + version)
- N blocks (full)
- balances HashMap (address → sat)
- nonces HashMap
- pubkey registry
- tx_block_height index

Persisted as one atomic tmp+rename operation. At 70 k blocks that's
a ~14 MB rewrite per save. Pre-`b363095` we did this every 100 blocks
or every 60 s; pre-`ea9e0bc` we *also* did it inline on every block,
which is what stole 8-9 s from the mining loop in the periodic spikes.

What broke: `b363095` made the per-block save a no-op while leaving
the inputs (faucet grants, in-memory balance writes) untouched. State
that wasn't a chain TX was now ephemeral. Since faucet didn't emit
TXs, faucet recipients silently disappeared on the next restart.

## What we move to (Bitcoin-style, OmniBus-tuned)

```
data/<chain>/
├── blocks/
│   ├── blk00000.dat       ← append-only, 128 MB cap, then rotate
│   ├── blk00001.dat
│   ├── ...
│   ├── rev00000.dat       ← undo data, parallel numbering
│   ├── rev00001.dat
│   └── index/             ← Zig-native key-value store
│       ├── manifest.bin
│       ├── 000001.log
│       └── 000001.sst     ← block_hash → (file_no, offset, height)
├── chainstate/            ← Zig-native key-value store
│   ├── manifest.bin
│   ├── 000001.log         ← write-ahead log
│   └── 000001.sst         ← {addr → balance, addr → nonce, ...}
├── mempool.dat            ← serialised mempool
└── peers.dat              ← peer addresses
```

Key design decisions tailored for OmniBus:

| Decision | Why |
|----------|-----|
| **Pure Zig KV store**, no LevelDB dependency | Keeps build simple. Our QPS is far below LevelDB's design point — a tiny WAL+SSTable in <600 LoC is enough. |
| **Block file size 128 MB** | Same as Bitcoin. At 60/min × ~1 KB/block we rotate every ~36 hours. |
| **Block height limit per file:** also 128 k blocks | Hard cap so a corrupted block file is bounded. |
| **Chainstate is a flat KV** (not UTXO model yet) | Bitcoin tracks every output as an entry. We use account-based balances (Ethereum-style). Smaller key space. UTXO can come later if we want full SPV proofs. |
| **Reorg undo data** | Same as Bitcoin's `revNNNNN.dat`. For every block, record `(addr, old_balance, new_balance)` pairs; reorg replays them in reverse. |
| **Mempool persist** | Same as Bitcoin — `mempool.dat` at graceful shutdown only. |
| **Migration tool** | One-shot: read old `chain.dat`, re-emit as `blkNNNNN.dat` + chainstate. Reversible by keeping the original file. |

## Component sizes (estimated)

| Module | LoC | Difficulty |
|--------|-----|------------|
| `core/store/block_files.zig` — append-only block writer + reader | 350 | Medium |
| `core/store/wal.zig` — write-ahead log for crash safety | 250 | Hard |
| `core/store/sstable.zig` — sorted string table reader/writer | 400 | Hard |
| `core/store/kv.zig` — thin KV wrapper over WAL+SSTable | 300 | Medium |
| `core/store/chainstate.zig` — typed wrapper over KV (balance/nonce/pubkey) | 200 | Easy |
| `core/store/block_index.zig` — block_hash → file:offset KV | 150 | Easy |
| `core/store/undo.zig` — reorg undo record format | 200 | Medium |
| `core/store/migration.zig` — one-shot chain.dat → new format | 300 | Medium |
| Mempool persist (already exists, minor change) | 50 | Easy |
| Integration into main.zig + RPC handlers | 200 | Medium |
| Tests + benchmarks | 600 | High effort |
| **Total** | **~3 000 LoC** | **3–5 working days** |

## Migration strategy

1. **Side-by-side first.** New code writes both old `chain.dat` (as
   today) and new `blocks/` + `chainstate/`. Read still comes from the
   old path. Run for one week on regtest + testnet.

2. **Switch read path** to new format with old kept as a checksum
   reference. If they diverge, log + alert.

3. **Drop old writer** once a full release cycle (30 days) without
   divergence is confirmed.

4. **Keep old chain.dat read path** indefinitely for restoring from
   archived backups.

## Crash-safety contract (target)

After the refactor, this test must pass:

```
1. wipe data/<chain>/
2. start node from genesis
3. run a workload: faucet claims, mining, signed transfers, exchange orders
4. send SIGKILL to the node mid-write (no graceful shutdown)
5. start node again
6. verify: every committed block survives, every committed balance
   change survives, mempool reloads, no manual repair needed
```

Today's chain.dat fails this test (we proved it). The new design
must pass.

## What stays the same

- Wire format for blocks (P2P doesn't care about local storage).
- RPC surface (`getblock`, `getaddressbalance`, `getrichlist` etc.).
- Genesis bootstrap path.
- Reorg / fork-choice rules.
- Validator set + slot-leader selection.
- Mining loop logic (orchestrator, stabilizer, slot-leader gate).

This is a storage layer swap, not a consensus change.

## Stretch goals (post-MVP)

- **Snapshots / pruning.** After N blocks the early `blkNNNNN.dat`
  files are append-only history; we can compress them into a single
  archive once they're past the deepest possible reorg.

- **SPV proofs.** With block files + chainstate it's straightforward
  to serve light-client merkle proofs without holding the whole chain.

- **`-reindex-chainstate`.** Drop chainstate, rebuild from blocks. Same
  CLI flag as Bitcoin.

- **Networked snapshots.** Bitcoin has `assumeutxo`; we could ship
  signed chainstate snapshots so a fresh node syncs in seconds.

## Open questions to resolve before coding

1. **Atomic batch granularity.** Bitcoin commits chainstate per block.
   At our 60/min that's a write every second — fine, but verify the
   WAL flush rate isn't a SSD-life issue on small VPSs.

2. **Account vs UTXO model.** Sticking with account-based balances
   (current design) keeps chainstate ~10× smaller than UTXO. But if
   we ever want script-based spending or coin selection at the chain
   layer, UTXO becomes mandatory. Decide before writing the SSTable
   schema.

3. **Endianness.** Bitcoin uses little-endian throughout. We've been
   inconsistent. Pick one (LE) and document it.

4. **Compaction.** SSTables need periodic merge. Background thread or
   on-demand at startup?

5. **Multi-chain support.** mainnet / testnet / regtest each get their
   own subdirectory? (Yes — already the convention.)

## Branch layout

```
arch/leveldb-storage         ← all storage refactor work, off main
  ├── core/store/            ← new modules
  ├── core/storage.zig       ← OLD, kept for migration tool reference
  └── tests/storage_*        ← new tests
```

Merge to `main` only after the side-by-side validation + the
crash-safety test pass on regtest *and* testnet.

## Why this matters

We've been losing data because storage was implicit and one-shot.
Bitcoin solved this in 2010 with the layered design above. Adopting
it doesn't make us "Bitcoin-derivative" — it makes us a proper L1
rather than a fancy in-memory toy that happens to mine blocks.

Until this lands, the band-aid is the background state-save thread
(`startStateSaveThread` in main.zig). It saves the same monolithic
`chain.dat` every 60 s, on a worker, off the mining hot path. That
keeps faucet grants and other in-memory writes durable across
restarts without re-introducing the p99 spike. Not pretty, not fast,
not ideal — but stops the bleeding while we build the real fix.
