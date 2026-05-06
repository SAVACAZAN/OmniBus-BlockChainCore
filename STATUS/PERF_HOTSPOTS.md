# PERF_HOTSPOTS.md — OmniBus-BlockChainCore static-analysis profile

Generated: 2026-05-07
Scope: chain hot paths — mining loop, block validation, signature verify, mempool.
Method: static read of `core/*.zig` (no `zig build bench` executed in this session;
benchmark.zig already wired but the per-iteration hot loops below were inspected
manually). All findings respect bare-metal constraints (no malloc post-init, no FP,
no syscalls in hot path).

> **Headline finding:** the PoW inner loop in `mineBlockForMiner` allocates a
> 64-byte hex string **on every nonce attempt** and compares ASCII characters
> instead of raw bytes. This single bug pinpoints throughput before any of the
> usual SHA-NI / SIMD work even matters.

---

## Top 5 hotspots (ranked by est. cycles × call frequency)

### 1. PoW inner loop — alloc + hex-encode + ASCII compare per nonce  *(CATASTROPHIC)*

- **Files:** `core/blockchain.zig:1124-1136` (loop), `core/hex_utils.zig:28-87`
  (`calculateBlockHashHex`, `hashBlock`, `isValidHashDifficulty`).
- **Why it's hot:** called up to `MAX_NONCE = 2^32` times per block. Per
  iteration the loop currently does:
  1. `hashBlock` builds a `[10000][]const u8` slice array on stack (10 000 ×
     `usize×2` = 160 KB stack frame, blown every call) — `hex_utils.zig:62`.
  2. `calculateBlockHashHex` calls `std.fmt.bufPrint` to format
     `index|timestamp|prev_hash_len|nonce` as **decimal text** (line 39-41),
     hashes it, then **`allocator.alloc(u8, 64)`** for the hex string and runs
     32 × `bufPrint("{x:0>2}")` to encode (line 52-55).
  3. `isValidHashDifficulty` compares `char == '0'` on the hex string
     (line 77-86) — twice the work of comparing raw bytes.
  4. Loser path: `self.allocator.free(hash)` on every miss
     (`blockchain.zig:1134`).
- **Estimated cost:** ~5-10 µs / nonce vs. theoretical ~250-500 ns for a pure
  SHA-256 double of a 100-byte buffer. **20-40× overhead on the miner's only
  hot loop.**
- **Fix (quick win, ~30 min):**
  - Build the header bytes **once** into a fixed `[var]u8 align(64)` buffer
    before the loop. Only the 8 nonce bytes change per iteration — patch them
    with `std.mem.writeInt(u64, buf[NONCE_OFFSET..][0..8], nonce, .little)` and
    re-hash.
  - Compare `[32]u8` raw hash against a precomputed `target: [32]u8` with
    `for (hash, target) |h, t| if (h < t) return true; if (h > t) return false;`
    instead of counting hex zeros.
  - Drop the per-iteration `allocator.alloc` / `free` entirely — return
    `[32]u8` from the hash function, hex-encode **once** after success.
- **Estimated speedup:** **20×–50×** on PoW hashrate. This is the biggest
  win in the entire codebase.
- **Effort:** quick win.

---

### 2. `Transaction.calculateHash` — 9 separate `bufPrint` calls per TX

- **File:** `core/transaction.zig:313-418`.
- **Why it's hot:** called for every TX in **every** Merkle root recomputation,
  every block validation, every `validateTransaction` (twice — once at lines
  986 and 1035 in `blockchain.zig`). Also called inside `Block.calculateMerkleRoot`
  (`block.zig:139`) and `Block.generateMerkleProof` (`block.zig:283`). With
  10 sub-blocks × N TXs and re-merkle in `validateBlock` (`blockchain.zig:1258`)
  this runs **3–5× per TX per block**.
- **Per-call cost:** 9× `std.fmt.bufPrint` for `id`, `amount`, `timestamp`,
  `nonce`, `scheme`, `fee`, `locktime`, `output_index`, `tx_type` — each does
  an internal format-state machine walk. Then a 2nd full SHA-256 for SHA256d
  (line 417).
- **Fix:**
  - Encode the integer fields **little-endian** with `std.mem.writeInt` directly
    into the hasher via a 64-byte stack scratch buffer — no decimal text. The
    consensus rule only requires deterministic bytes; ASCII decimal is gratuitous.
  - This breaks hash compatibility with existing chain — gate behind a hardfork
    height OR keep the ASCII path for chain-replay only and use the binary path
    in a side hash for mempool dedup.
  - Cache the result on the `Transaction` struct itself once computed (already
    a `hash: []const u8` field — populate it eagerly after sign and skip
    recompute in `calculateMerkleRoot` if `tx.hash.len == 64`).
- **Estimated speedup:** 4–6× on TX hash; cumulative ~2× on block validation.
- **Effort:** quick win for the **caching path** (~30 min). Big rock for the
  binary-encoding hardfork.

---

### 3. `validateTransaction` — O(mempool_len) per TX, called per TX

- **File:** `core/blockchain.zig:846-1044`, with the offenders at
  `getPendingOutgoing` (815-823) and `getNextAvailableNonce` (834-844).
- **Why it's hot:** every `mempool.add` and every new-block-validation calls
  `validateTransaction`, which then calls `getNextAvailableNonce` →
  **linear scan over `self.mempool.items`** (`blockchain.zig:838`). For
  v1 TXs `getPendingOutgoing` does another linear scan (`blockchain.zig:817`).
  At 10 000-TX mempool that's **20 000 string-compares per validate call**,
  and a block with 1 000 TXs validates 1 000 × 20 000 = 20 M compares — pure
  O(N²).
- **Same pattern repeats** in `mempool.zig`:
  - `add` (line 98): RBF scan O(N).
  - `getPackageFee` (153-176): two O(N) scans for parent/child.
  - `replaceByNonce` (501): O(N).
  - `removeConfirmed` (358-368): O(N×M) — nested loop over confirmed × mempool.
- **Fix:**
  - Replace the `array_list.Managed(MempoolEntry)` + linear scans with a
    `StringHashMap` keyed by `from_address` → `struct { pending_count: u32,
    pending_outgoing_sat: u64, head_index: u32 }` — already half done via
    `pending_count` (mempool.zig:42), but `validateTransaction` reads the
    chain's `mempool` field directly, not the dedup index.
  - For RBF/replaceByNonce, key by `(from_address, nonce)` → entry index.
  - `removeConfirmed`: build a `StringHashMap(void)` of confirmed TX hashes
    once, then single pass over mempool — converts O(N×M) → O(N+M).
- **Estimated speedup:** at 5 000-TX mempool, 50–200× on block validation
  throughput. Becomes a non-issue at small mempools.
- **Effort:** big rock — requires a small refactor to share the index between
  `Blockchain.mempool` and the dedicated `Mempool` type (currently two parallel
  TX pools, see also `core/main.zig` mempool init).

---

### 4. `mineBlockForMiner` per-TX UTXO + balance + index work — 6 hashmap puts per TX

- **File:** `core/blockchain.zig:1138-1187` (mining apply path) and the
  near-duplicate at `applyBlock:1882-1986`.
- **Why it's hot:** for every TX in the block (and every block), the inner loop:
  1. `selectUTXOs` allocates a `Selection` containing an `array_list` of UTXOs
     (`blockchain.zig:1152`, allocator: heap) — `defer selection.utxos.deinit`
     line 1159 — **allocator.alloc + free on the hot path**.
  2. Per UTXO: `spendUTXO` (hashmap remove) + iterates inputs.
  3. `addUTXO` (hashmap put) for change + recipient.
  4. `debitBalance` + `creditBalance` (each takes the global `bc.mutex`,
     line 601/666) — **two mutex roundtrips per TX**.
  5. `nonces.put`, `tx_block_height.put`, `indexAddressTx` (which itself
     allocates an array_list per address, line 578), `applyOpReturnRoles`,
     two more `indexAddressTx`, `addUTXO` recipient.
- This is **duplicated** between `mineBlockForMiner` (mine path) and
  `applyBlock` (peer block path). They will drift; e.g., the v1 fallback comment
  at lines 1147-1155 is mirrored at 1947-1957.
- **Fix:**
  - Bundle balance + nonce + height puts into one batched HashMap pass:
    take `mutex` **once** at start of the TX loop, do all puts under it,
    release at the end. Currently each `creditBalance` re-locks
    (`blockchain.zig:601`).
  - Make the UTXO `Selection` use a fixed `[8]UTXO` stack array — vast majority
    of TXs select 1–2 UTXOs, the heap case is rare.
  - Deduplicate `mineBlockForMiner` and `applyBlock` into a shared
    `applyTxToState(tx, height)` helper.
- **Estimated speedup:** 2–3× on per-block apply at 1 000 TXs (mostly from
  removing mutex churn and avoiding Selection alloc).
- **Effort:** mid-tier (1-2 h). Quick win on just the mutex consolidation
  (~20 min).

---

### 5. `SubBlockEngine.tick` — per-tick allocator init + re-hash + debug print

- **File:** `core/sub_block.zig:252-300`, called 10 times back-to-back per
  block from `core/main.zig:2081-2084`.
- **Why it's hot:**
  - Each tick `SubBlock.init` initialises a `array_list.Managed(Transaction)`
    against `self.allocator` (heap) — line 51. With ~10 000 TXs flowing through
    a 10-tick burst, that's 10 alloc-grow cycles **per block**.
  - `addTransaction` does `try self.transactions.append(tx)` (line 60) which
    can reallocate; the inner loop in `tick` calls it for **every TX in the
    pending pool** (line 266-268), even though `pending_txs` is the SAME slice
    handed in — sub-block 0 and sub-block 9 currently both contain the full
    TX set, so each TX is hashed 10× into the merkle root.
  - `std.debug.print` formatted string at `sub_block.zig:274` runs every tick
    (10× per block) and locks stderr.
  - `calcMerkleRoot` (line 69-77) hashes every TX hash sequentially — fine
    when correct, but currently called 10 times on the same TX set.
- **Fix:**
  - Partition `pending_txs` into 10 slices once before the loop (lines/index
    bounds = `pending_txs[i*N/10..(i+1)*N/10]`). Today every sub-block holds
    every TX — wasted hashing.
  - Replace the heap `array_list.Managed` with a slice view + `tx_count`;
    sub-blocks don't need to own TX storage if the parent slice outlives them.
  - Hide `std.debug.print` behind a `if (DEBUG_SUB_BLOCKS)` comptime flag —
    it serializes 10 stderr writes per block.
  - Reuse the `KeyBlock.sub_blocks` slot's hasher state across ticks
    (incremental SHA on the running merkle).
- **Estimated speedup:** 2–10× on sub-block phase. Phase currently runs
  back-to-back so freed time directly raises block rate.
- **Effort:** quick win.

---

## Honourable mentions (not top 5 but cheap fixes)

- **`core/secp256k1.zig` is just a 50-line wrapper around
  `std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256oSha256`** — there is **no custom
  field arithmetic, no NAF, no precomputed tables, no SIMD**. Verify is done
  the slow way through Zig's stdlib. *Not* a quick win (rewriting field
  arithmetic with `@Vector(4, u64)` and Montgomery reduction is ~2-3 weeks of
  work) but worth flagging — once hotspot #1 is fixed, signature verification
  in `validateTransaction:1003` will dominate. Recommendation: link
  libsecp256k1 (BSD) or write `secp256k1_fe_mul` with Montgomery + endomorphism
  split, target ~300 cycles/mul vs. stdlib's ~2 000.
- **`core/crypto.zig:42-47` `ripemd160` is a stub** — it returns the first 20
  bytes of SHA-256 instead of real RIPEMD-160. The proper implementation is
  in `core/ripemd160.zig` (called by `secp256k1.privateKeyToHash160`). The
  `Crypto.ripemd160` shim risks producing wrong hashes if anything other than
  `secp256k1.zig` calls it — non-perf bug but high-impact correctness.
- **`block.calculateMerkleRoot` allocates `[MAX_BLOCK_TX][32]u8` = potentially
  320 KB on stack per call** (`block.zig:136`). Fine on x86_64 default 8 MB
  stack, will blow on smaller stacks (Windows default, or threadpool workers).
  Consider a comptime-sized scratch buffer scoped to caller, or a heap-arena
  freed at end of block.
- **`hashBlock` similarly stack-allocates `[10000][]const u8` = 160 KB**
  (`hex_utils.zig:62`) inside a function called potentially 2³² times per block.
- **`StringHashMap`s in `Blockchain` and `Mempool` use `std.mem.eql` /
  hashing on slice keys** — fine, but every `from_address` lookup does a
  byte-by-byte string compare. Addresses are bounded to ~64 chars so this is
  ~50 ns/lookup; not catastrophic but at 1 000 TXs × 6 lookups/TX = 300 µs/block.
  Switching the key to a `[20]u8` hash160 (already computed) would let the
  hashmap use direct integer compare.

---

## Quick wins (< 1 h each)

| # | Fix | File | Est. speedup |
|---|-----|------|-------------|
| 1 | Hoist header bytes out of PoW loop, raw-byte target compare, no per-iteration alloc | `blockchain.zig:1124`, `hex_utils.zig` | **20–50× hashrate** |
| 2 | Cache `tx.hash` after first compute; skip recompute in merkle / validate when set | `block.zig:139,283`, `blockchain.zig:986,1035` | 2× block validation |
| 3 | Hide `[SUB #x/10]` debug print behind comptime flag | `sub_block.zig:274` | small but free |
| 4 | Partition `pending_txs` across 10 sub-blocks instead of giving all to each | `main.zig:2081-2084` | 5–10× sub-block phase |
| 5 | Single `mutex.lock` for the whole TX-apply loop in `mineBlockForMiner` | `blockchain.zig:1138-1187` | ~30% on mining apply |
| 6 | Replace `getPendingOutgoing` linear scan with the hashmap already in `Mempool.pending_count` | `blockchain.zig:815-823` | huge at large mempool |

## Big rocks (multi-hour to multi-day)

| # | Refactor | Effort | Payoff |
|---|----------|--------|--------|
| A | Binary-canonical TX hash (drop `bufPrint` chain). Hardfork-gated. | 1-2 days incl. tests + replay | 4–6× TX hash, 2× block apply |
| B | Unify `Blockchain.mempool` (Managed array) and `Mempool` type — single source of truth, hashmap-indexed | 2 days | Eliminates O(N²) mempool churn |
| C | Replace stdlib secp256k1 with libsecp256k1 link OR custom Montgomery field arithmetic + GLV endomorphism + windowed NAF | 2-3 weeks | 5–10× ECDSA verify (becomes the bottleneck once hotspot #1 is fixed) |
| D | SHA-NI intrinsic path for `Crypto.sha256` / `sha256d` (x86 SHA extensions) — comptime detect, fall back to stdlib | 1 week | 4–8× SHA throughput on supported CPUs |
| E | Deduplicate `mineBlockForMiner` and `applyBlock` UTXO/balance/index logic into a shared `applyTxToState` | 1 day | Maintainability + halves the surface for fixing hotspot #4 |

---

## Recommended order of attack

1. **Hotspot #1 (PoW alloc/hex)** — single afternoon, biggest absolute gain.
2. **Quick wins #2, #3, #4, #5** — together another ~3-5× on the rest of the
   block production pipeline.
3. **Hotspot #3 (mempool O(N²))** — only urgent once you actually fill the
   mempool to thousands of TXs in stress tests.
4. **Big rock C (secp256k1)** — only after #1 is done, otherwise you're
   optimising the wrong thing.

After #1 the miner's hashrate ceiling moves from "alloc-bound" to "SHA-bound",
which is where any further work (SHA-NI, custom ECDSA) starts paying off.
Until then those investments are dwarfed by the per-iteration heap traffic.
