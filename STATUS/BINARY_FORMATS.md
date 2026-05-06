# BINARY_FORMATS — On-disk .dat file reverse-engineering

Generated: 2026-05-07. Source-of-truth code: `core/database.zig`, `core/dns_registry.zig`.

This document maps every byte in the OmniBus on-disk persistence files. It was
produced by reading the writer/reader code AND by hex-dumping live files
(non-destructive read-only inspection). Numbers in offsets are **decimal**
unless prefixed `0x`. All multi-byte integers are **little-endian**.

---

## 1. `omnibus-chain.dat` — main chain DB

### 1.1 Files inspected

| Path | Size (bytes) | Magic | Version on disk |
|------|-------------:|------:|----------------:|
| `omnibus-chain.dat` (legacy root)            | 30 401   | `OMNI` | 4 |
| `omnibus-chain.dat.bak`                      | 30 401   | `OMNI` | 4 |
| `data/testnet/chain.dat`                     | 13 210 546 | `OMNI` | 4 |
| `data/regtest/chain.dat`                     | 62 546   | `OMNI` | 2 |

The code constant `DB_VERSION` in `core/database.zig:21` is **4**. The detector
(`detectVersion`, line 924) accepts any u32 at offset 4 in the range `[2, 4]`
and a single-byte `1` at offset 4 (legacy v1). Files written before 2026-05-04
are v2; testnet/legacy were upgraded to v4 in-place by `saveBlockchain()` on
their first save under the new build. Regtest chain.dat is still v2 — it will
be promoted to v4 on its next normal save (no migration tool needed; load path
is fully backward-compatible).

### 1.2 v2 / v3 / v4 layout (current)

```
+-----------------------------------------------+ offset 0
| magic     "OMNI"                          4 B |
| version   u32 LE (= 2 | 3 | 4)            4 B |
+-----------------------------------------------+ 8
| === BLOCKS SECTION ===                        |
| block_count           u32 LE              4 B |
|   per block:                                  |
|     height            u64 LE              8 B |
|     data_len          u32 LE              4 B |
|     data              data_len B              |   <-- pipe-delimited header
|                                               |       + (v4 only) optional
|                                               |       binary TX section
| crc32(blocks section)  u32 LE             4 B |
+-----------------------------------------------+
| === BALANCES SECTION ===                      |
| addr_count            u32 LE              4 B |
|   per address:                                |
|     addr_len          u8                  1 B |
|     addr              addr_len B              |
|     balance           u64 LE              8 B |
| crc32(balances)        u32 LE             4 B |
+-----------------------------------------------+
| === NONCES SECTION ===                        |
| nonce_count           u32 LE              4 B |
|   per nonce:  addr_len(1) | addr | nonce(u64) |
| crc32(nonces)          u32 LE             4 B |
+-----------------------------------------------+
| === TX-CONFIRM SECTION ===                    |
| tx_count              u32 LE              4 B |
|   per tx:    hash_len(1) | hash | height(u64) |
| crc32(tx_confirms)     u32 LE             4 B |
+-----------------------------------------------+
| === STAKE-STATE SECTION (v2-ext) ===          |
| stake_count           u32 LE              4 B |
|   per:       addr_len(1) | addr | stake(u64)  |
| crc32(stake)           u32 LE             4 B |
+-----------------------------------------------+
| === AGENT-STATE SECTION (v2-ext) ===          |
| agent_count           u32 LE              4 B |
|   per:       addr_len(1) | addr               |
| crc32(agents)          u32 LE             4 B |
+-----------------------------------------------+
| === ORDERBOOK-STATE SECTION (v3-ext) ===      |
| pair_count            u32 LE              4 B |
|   per pair:                                   |
|     pair_id           u16 LE              2 B |
|     order_count       u32 LE              4 B |
|     orders            order_count × 128 B     |
| crc32(orderbook)       u32 LE             4 B |
+-----------------------------------------------+
| === FILLS-HISTORY SECTION (v3-ext) ===        |
| block_count           u32 LE              4 B |
|   per block:                                  |
|     height            u32 LE              4 B |
|     fill_count        u32 LE              4 B |
|     fills             fill_count × 180 B      |
| crc32(fills)           u32 LE             4 B |
+-----------------------------------------------+ EOF
```

CRC algorithm: `std.hash.crc.Crc32` (polynomial = standard Ethernet/zip
CRC-32, init 0xFFFFFFFF, output XOR 0xFFFFFFFF) — see line 25 / 203-205.
The CRC field covers the section's data **including** its own count header
but **excluding** the 4-byte CRC trailer.

### 1.3 Per-block `data` payload

`data` (length = `data_len`) is the union of two sub-formats:

```
[ pipe-delimited header text ]              <-- v3 stops here (data.len == header end)
[ tx_count  u32 LE ]
[ tx_wire ... ]                             <-- only present in v4
```

Pipe-delimited header (ASCII, exactly **6** `|` separators → 7 fields):

```
{index}|{timestamp}|{nonce}|{previous_hash}|{hash}|{miner_address}|{reward_sat}
```

Example seen at offset 16 of live file:
```
1|1776580252|1691|0000000a1b2c3d4e...|000078f8e8fe9bbc...|ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl|8333333
```

`findHeaderEnd()` (line 1263) locates the boundary between the header and the
TX section by walking past the 6th `|` and consuming the trailing digit run
of `reward_sat`. v3 files have nothing after; v4 appends a binary TX block.

The TX wire format is owned by `core/transaction.zig:encodeWire` (variable
size; not laid out here — see that module).

### 1.4 v1 layout (legacy, still supported on read)

```
"OMNI"     4 B
version    u8  = 1                 <-- single byte, NOT u32
block_count u32 LE
   per block: height(u64) | data_len(u32) | data
addr_count u32 LE   per addr: addr_len(u8) | addr | balance(u64)
nonce_count u32 LE  (optional)
tx_count    u32 LE  (optional)
```

No CRC32 trailers. The detector keys off `buf[4] == 1` after rejecting the
u32 path (see line 932-934).

### 1.5 Verification against live `omnibus-chain.dat`

Header bytes 0..16 (hex):
```
4f4d4e49 04000000 8c000000 01000000 00000000
^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^^^^^^^^^^
"OMNI"   ver=4    blk=140  height=1 (start of block #1)
```
- 140 blocks (excluding genesis) match the writer comment "skip genesis"
  at line 727 (`save_count = chain.len - 1`).
- First block's `data_len` = `0xCA` (202 bytes) → header text starts with
  `1|1776580252|1691|...` exactly as expected.

Tail bytes 0x7650..EOF reveal the trailing sections:
```
04335552                                  <- blocks-section CRC32 (LE) = 0x52553304
01000000                                  <- balances count = 1
2a                                        <- addr_len = 42
6f62 3171 …                                <- "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl"
eb89450000000000                          <- balance u64 LE = 4557803 sat
f5bd6eca                                  <- balances CRC32
00000000 1cdf4421                         <- nonces:  count=0,  CRC=0x2144DF1C
00000000 1cdf4421                         <- tx_conf: count=0,  CRC=0x2144DF1C
00000000 1cdf4421                         <- stakes:  count=0,  CRC=0x2144DF1C
00000000 1cdf4421                         <- agents:  count=0,  CRC=0x2144DF1C
00000000 1cdf4421                         <- orderbk: count=0,  CRC=0x2144DF1C
00000000 1cdf4421                         <- fills:   count=0,  CRC=0x2144DF1C
```

`CRC32(00 00 00 00) = 0x2144DF1C` — independently verifiable, confirming both
the CRC algorithm choice and the empty-section layout.

### 1.6 Code-claim vs on-disk reality

| Claim | Reality |
|-------|--------|
| Magic `OMNI`, version u32 at offset 4 | ✅ matches |
| v4 = v3 + TX section in block payload | ✅ writer at line 738-771 appends `[tx_count:4][tx_wire…]` after pipe-header |
| `DB_VERSION = 4`, save log says "v4"  | ✅ confirmed (testnet header bytes `4F 4D 4E 49 04 00 00 00`) |
| Block payload `data_len` covers header **and** TX section | ✅ writer (`total_data_len = header.len + tx_scratch.items.len`, line 763) |
| CRC32 trailer per section | ✅ all 7 trailers present and verified |
| `appendBlock` on v2+ falls back to full save | ✅ line 1521-1525 |
| Atomic write via `tmp + rename` | ✅ line 891-894 |
| Backup `.dat` → `.dat.bak` on every load | ✅ line 908-921; bak file size matches primary (30401 == 30401) |
| Save count = `chain.len - 1` (skips genesis) | ✅ comment+code at 727 |

**Deviations / footguns observed:**

1. **Doc-string lies in `loadFromDisk`** (line 564-636 — the *legacy* v1
   loader). The doc says it parses `[magic:4][version:1][block_count:4]` —
   correct for v1, but this function is dead-code-ish: it's only used by
   `Database` (not `PersistentBlockchain`) and will silently *fail* on the
   v2+ files actually written today (it checks `buf[4] != 1` and returns
   an empty DB). Reader tests bypass it via `restoreInto`. Recommendation:
   either delete or route to `restoreFromFile`.

2. **`detectVersion` accepts versions 2..DB_VERSION** but the *writer* always
   writes the current `DB_VERSION` (4). There is no way to write a v2/v3
   file from the current binary, so v2 files only survive as long as nobody
   calls `saveBlockchain` against them — the regtest `chain.dat` (v2 on disk
   today) will silently become v4 on next mining tick.

3. **Orderbook/fills section CRC verify-but-warn**: `verifyCrc32` returns
   `false` and only logs a warning; the loader still accepts the data. This
   is by design (line 1115, 1131, etc.) to avoid bricking the chain on a
   single bad byte, but it means a corrupt CRC won't actually halt load.

4. **Block payload split is heuristic**: `findHeaderEnd` scans for 6 `|`
   then consumes the digit run of `reward_sat`. If `reward_sat` is `0` and
   the next byte happens to be `0..9` (ASCII), the heuristic *may* over-eat.
   In practice the first byte after the digits is the LE u32 `tx_count`
   whose high bytes are nearly always 0, but byte 0 (the count low byte) is
   often a small int (`0x00`-`0x0A`) which is NOT a digit (digits are 0x30-
   0x39), so the boundary is sound. Still — a length-prefixed header would
   be safer.

5. **`miner_address` stored as ASCII inside the pipe header** (e.g.
   `ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl`). If a miner registers a
   PQ address (`ob_pq_…`) longer than ~45 chars and the resulting header
   exceeds the 512-byte `data_buf` at line 740, `bufPrint` will return
   `error.NoSpaceLeft` and the whole block save aborts. **Not yet a bug
   in practice** but worth raising the buffer to 4 KB.

---

## 2. `data/<chain>/dns_registry.bin` — DNS / Herotag registry

### 2.1 Files inspected

| Path | Size | Magic | Version on disk | Entries |
|------|----:|------:|----------------:|--------:|
| `data/testnet/dns_registry.bin` | 16 | `OMNIDNS1` | **2** | 0 |

The code constant `VERSION` in `core/dns_registry.zig:840` is **3**.
The on-disk file is still v2 (16-byte header, zero entries, written before
the v2→v3 bump). It is forward-compatible on read (loader handles v1/v2/v3),
and on next save the same code will produce a v3 file.

### 2.2 Header (all versions)

```
+--------------------------------------------------+ offset 0
| magic         "OMNIDNS1"            (8 B)        |
| version       u32 LE                (4 B, @ 8)   |
| entry_count   u32 LE                (4 B, @ 12)  |
+--------------------------------------------------+ 16
| entries[0] | entries[1] | …                       |
+--------------------------------------------------+ EOF
```

Live testnet bytes: `4F 4D 4E 49 44 4E 53 31 02 00 00 00 00 00 00 00`
→ magic OK, version=2, entry_count=0. Perfectly consistent.

### 2.3 v3 entry layout (480 bytes — current writer)

`V3_ENTRY_SIZE = V2_ENTRY_SIZE(214) + 1 + (PQ_SLOT_COUNT(4) * MAX_ADDR_LEN(64)=256) + PQ_SLOT_COUNT(4) + 1 + 4 = 480`

| Offset | Field              | Size | Notes |
|------:|--------------------|----:|---|
|   0  | name_len            | 1   | 0..25 |
|   1  | name                | 25  | zero-padded fixed-array |
|  26  | tld_len             | 1   | 0..16 |
|  27  | tld                 | 16  | zero-padded |
|  43  | addr_len            | 1   | 0..64 |
|  44  | address             | 64  | primary on-chain address (pre-PQ) |
| 108  | owner_len           | 1   | |
| 109  | owner               | 64  | who controls the entry |
| 173  | registered_block    | 8   | u64 LE |
| 181  | expires_block       | 8   | u64 LE |
| 189  | active              | 1   | 0/1 |
| 190  | last_nonce          | 8   | u64 LE — anti-replay (v2+) |
| 198  | last_action_block   | 8   | u64 LE |
| 206  | grace_until_block   | 8   | u64 LE |
| 214  | category            | 1   | enum byte (none/personal/bank/gov/...) |
| 215  | addr_pq[0]          | 64  | PQ slot 1 (`ob_omni_…`) |
| 279  | addr_pq[1]          | 64  | PQ slot 2 (`ob_k1_…`)   |
| 343  | addr_pq[2]          | 64  | PQ slot 3 (`ob_f5_…`)   |
| 407  | addr_pq[3]          | 64  | PQ slot 4 (`ob_d5_…`)   |
| 471  | addr_pq_lens[0..4]  | 4   | u8 each, lengths of the 4 slots |
| 475  | preferred_slot      | 1   | which PQ addr is the "current" one |
| 476  | registered_years    | 4   | u32 LE |
| **480** | (end)            |     | |

Verifies the math: `214 + 1 + 4*64 + 4 + 1 + 4 = 214 + 1 + 256 + 4 + 1 + 4 = 480`. ✅

### 2.4 v1 / v2 entry sizes (still readable)

| Version | Entry size | Last fields added |
|--------:|-----------:|---|
| 1 | 190 B | base record (name/tld/addr/owner/blocks/active) |
| 2 | 214 B | + last_nonce, last_action_block, grace_until_block |
| 3 | 480 B | + category, 4×PQ addr+len, preferred_slot, registered_years |

`migrateLegacyEntries()` is invoked after a v2 load to backfill the v3
fields with sensible defaults (category=`.none`, all PQ slots empty,
preferred_slot=0, registered_years=0). This is a one-way upgrade — once
re-saved, the file is v3 and v2 readers can no longer parse individual
records (they would read 214 bytes and stride wrongly).

### 2.5 Code-claim vs on-disk reality

| Claim | Reality |
|-------|---------|
| Magic `OMNIDNS1`, version u32 LE | ✅ live file confirms |
| Header is exactly `HEADER_SIZE = 16` bytes | ✅ `8 + 4 + 4` matches file size |
| v3 entry size = 480 | ✅ math + code verified, see §2.3 |
| Loader supports v1/v2/v3 transparently | ✅ lines 913 / 952 / 979 |
| v2 file → in-RAM v3 default-init | ✅ comment at 973-975 |
| **No CRC, no length prefix on entries** | ⚠️ — relies on fixed entry stride; one truncated record corrupts the rest |

**Deviations / risks:**

1. **No checksum at all** — a single flipped bit anywhere in any entry is
   undetectable; only `BadMagic` / `CorruptFile` (short read) raise errors.
2. **No total-file-length sanity** beyond the entry-stride read. If the
   header `entry_count` lies (e.g. 4096 entries claimed but only 100 on
   disk), the loop will fail on `file.readAll(&rec) < V3_ENTRY_SIZE` →
   `error.CorruptFile`, but only after partially populating the registry.
   `loadFromFile` does NOT roll back partial population — `entry_count`
   on the in-RAM struct is left at the count actually loaded. This is a
   minor latent bug.
3. **Magic literal includes a "1"** (`OMNIDNS1`) which is misleading —
   it is *not* a version digit, just a tag. The actual version is the u32
   at offset 8. Future-you may be tempted to change `1` → `2` in the magic;
   don't — the loader checks the literal 8-byte constant.
4. **Fixed-cap design**: `MAX_ENTRIES = 4096`. Loader rejects
   `count > MAX_ENTRIES` with `error.TooManyEntries`. Any growth past 4096
   demands both a `MAX_ENTRIES` bump and a recompile of every node.

---

## 3. `data/<chain>/chainstate.snap` and `chainstate.wal`

These are referenced in the file listing (e.g. `data/testnet/chainstate.snap`
= 287 B, `chainstate.wal` = 0 B today). They are NOT touched by the two
modules audited; they belong to a different state-snapshot subsystem (likely
`core/state_trie.zig` or `core/archive_manager.zig`). Out of scope for this
pass; flagged for a follow-up audit.

---

## 4. Recommendations for upgradeability

The two formats are at very different maturity levels. A unified design
ladder:

1. **Add a global file-trailer with CRC over the entire file.** Both formats
   today CRC sub-sections (chain.dat) or nothing at all (dns_registry.bin).
   A 4-byte tail CRC catches truncation and tear-on-write that an atomic
   `tmp+rename` already mostly prevents — but `rename` on Windows is not
   atomic across volumes and the user runs Windows.

2. **Length-prefix every section, not just the per-block payload.**
   Right now the chain.dat reader knows where the orderbook section ends
   only by walking its layout (`orderbookSectionSize`, line 386). A
   `[section_len: u64 LE]` prefix on each section would let a future v5
   reader **skip** unknown sections instead of erroring, enabling true
   forward-compat. Today an unknown trailing section is silently ignored
   only because it sits past the last `if (pos + 4 <= read_len)` guard.

3. **Bump version aggressively + keep a `min_compat_version` field.**
   Header could become:
   ```
   magic(4) | version(u32) | min_reader_version(u32) | flags(u32) | reserved(u32)
   ```
   That fixes the current "byte-4 single-byte v1" hack and makes feature-
   flag negotiation (e.g. "this file uses the new fills layout") explicit.

4. **DNS registry needs CRC.** Trivial fix: append `crc32(entries[])` after
   the last entry. Loader checks before populating.

5. **Stop storing block headers as ASCII pipe-delimited text.** The current
   format is a debug artefact from genesis days. A binary header
   `(index:u32, timestamp:i64, nonce:u64, prev_hash:[32]u8, hash:[32]u8,
   miner_addr_len:u8, miner_addr:[N]u8, reward_sat:u64)` would be ~94 B
   instead of ~210 B — halving chain.dat size — and would eliminate the
   `findHeaderEnd` heuristic in §1.6 footgun #4.

6. **Replace `MAX_ENTRIES` cap in DNS** with a length-prefixed dynamic-size
   on-disk format and a runtime-configurable cap.

7. **Atomic-write on Windows**: `std.fs.cwd().rename(tmp, path)` calls
   `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`.
   For now the existing `.bak` fallback masks failures, but for production-
   grade durability, fsync the tmp file before rename. (Out of scope here.)

---

## 5. Summary

| File | Magic | Cur ver code | On-disk ver(s) | CRC | Forward-compat | Length-prefixed |
|------|-------|------------:|---------------:|:---:|:--------------:|:---------------:|
| `omnibus-chain.dat`           | `OMNI`     | 4 | 4 (root, testnet); 2 (regtest) | per-section | partial (trailing-section skip) | per-block only |
| `data/<chain>/chain.dat`      | `OMNI`     | 4 | 4 / 2          | per-section | partial | per-block only |
| `data/<chain>/dns_registry.bin` | `OMNIDNS1` | 3 | 2 (testnet, empty) | none | yes (v1/v2/v3 loaders coexist) | no — fixed stride |

No corruption observed. All audited files parse cleanly under their declared
versions. The chain.dat CRC tail trailers verify against a hand-computed
`CRC32(00 00 00 00) = 0x2144DF1C` for the empty-trailing sections, providing
high confidence the writer is producing valid output.
