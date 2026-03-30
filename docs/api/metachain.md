# Module: `metachain`

> EGLD-style metachain coordination — aggregates shard headers, cross-shard communication, meta-block finalization.

**Source:** `core/metachain.zig` | **Lines:** 385 | **Functions:** 13 | **Structs:** 4 | **Tests:** 9

---

## Contents

### Structs
- [`ShardBlockHeader`](#shardblockheader) — Header rezumat al unui shard block — trimis la Metachain pentru confirmare
- [`CrossShardReceipt`](#crossshardreceipt) — Cross-shard receipt — confirmă că o TX cross-shard a fost procesată
La EGLD: faz...
- [`MetaBlock`](#metablock) — MetaBlock — blocul Metachain-ului (1 per secundă)
- [`Metachain`](#metachain) — Metachain — chain de MetaBlock-uri, coordonator global

### Constants
- [3 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`addShardHeader()`](#addshardheader) — Adaugă header-ul unui shard la acest MetaBlock
- [`addCrossReceipt()`](#addcrossreceipt) — Adaugă un receipt cross-shard
- [`calculateHash()`](#calculatehash) — Calculează hash-ul MetaBlock-ului (SHA256 peste toate datele)
- [`isComplete()`](#iscomplete) — Checks whether the complete condition is true.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`getHeight()`](#getheight) — Returns the current height.
- [`getLatestHash()`](#getlatesthash) — Returns the current latest hash.
- [`beginMetaBlock()`](#beginmetablock) — Creează un nou MetaBlock gol pentru height-ul următor
- [`finalizeMetaBlock()`](#finalizemetablock) — Finalizează MetaBlock-ul curent: calculează hash + procesează receipts...
- [`printStatus()`](#printstatus) — Performs the print status operation on the metachain module.

---

## Structs

### `ShardBlockHeader`

Header rezumat al unui shard block — trimis la Metachain pentru confirmare

| Field | Type | Description |
|-------|------|-------------|
| `shard_id` | `u8` | Shard_id |
| `block_height` | `u64` | Block_height |
| `block_hash` | `[32]u8` | Block_hash |
| `tx_count` | `u32` | Tx_count |
| `timestamp` | `i64` | Timestamp |
| `miner` | `[]const u8` | Miner |
| `reward_sat` | `u64` | Reward_sat |

*Defined at line 20*

---

### `CrossShardReceipt`

Cross-shard receipt — confirmă că o TX cross-shard a fost procesată
La EGLD: faza 1 = scade din shard sursei; faza 2 = creditează în shard destinației

| Field | Type | Description |
|-------|------|-------------|
| `tx_hash` | `[32]u8` | Tx_hash |
| `from_shard` | `u8` | From_shard |
| `to_shard` | `u8` | To_shard |
| `from_address` | `[]const u8` | From_address |
| `to_address` | `[]const u8` | To_address |
| `amount_sat` | `u64` | Amount_sat |
| `phase` | `CrossShardPhase` | Phase |
| `meta_height` | `u64` | Meta_height |

*Defined at line 32*

---

### `MetaBlock`

MetaBlock — blocul Metachain-ului (1 per secundă)

| Field | Type | Description |
|-------|------|-------------|
| `height` | `u64` | Height |
| `timestamp` | `i64` | Timestamp |
| `previous_hash` | `[32]u8` | Previous_hash |
| `hash` | `[32]u8` | Hash |
| `shard_headers` | `array_list.Managed(ShardBlockHeader)` | Shard_headers |
| `cross_receipts` | `array_list.Managed(CrossShardReceipt)` | Cross_receipts |
| `total_tx_count` | `u64` | Total_tx_count |
| `active_shards` | `u8` | Active_shards |

*Defined at line 50*

---

### `Metachain`

Metachain — chain de MetaBlock-uri, coordonator global

| Field | Type | Description |
|-------|------|-------------|
| `chain` | `array_list.Managed(MetaBlock)` | Chain |
| `coordinator` | `ShardCoordinator` | Coordinator |
| `allocator` | `std.mem.Allocator` | Allocator |
| `pending_receipts` | `array_list.Managed(CrossShardReceipt)` | Pending_receipts |

*Defined at line 141*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `ShardCoordinator` | `shard_coord_mod.ShardCoordinator` | Shard coordinator |
| `METACHAIN_SHARD` | `shard_coord_mod.METACHAIN_SHARD` | M e t a c h a i n_ s h a r d |
| `CrossShardPhase` | `enum(u8) {` | Cross shard phase |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, height: u64, prev_hash: [32]u8) MetaBlock {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `height` | `u64` | Height |
| `prev_hash` | `[32]u8` | Prev_hash |

**Returns:** `MetaBlock`

*Defined at line 68*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *MetaBlock) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MetaBlock` | The instance |

*Defined at line 81*

---

### `addShardHeader()`

Adaugă header-ul unui shard la acest MetaBlock

```zig
pub fn addShardHeader(self: *MetaBlock, hdr: ShardBlockHeader) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MetaBlock` | The instance |
| `hdr` | `ShardBlockHeader` | Hdr |

**Returns:** `!void`

*Defined at line 87*

---

### `addCrossReceipt()`

Adaugă un receipt cross-shard

```zig
pub fn addCrossReceipt(self: *MetaBlock, receipt: CrossShardReceipt) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MetaBlock` | The instance |
| `receipt` | `CrossShardReceipt` | Receipt |

**Returns:** `!void`

*Defined at line 96*

---

### `calculateHash()`

Calculează hash-ul MetaBlock-ului (SHA256 peste toate datele)

```zig
pub fn calculateHash(self: *MetaBlock) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MetaBlock` | The instance |

*Defined at line 101*

---

### `isComplete()`

Checks whether the complete condition is true.

```zig
pub fn isComplete(self: *const MetaBlock, expected_shards: u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MetaBlock` | The instance |
| `expected_shards` | `u8` | Expected_shards |

**Returns:** `bool`

*Defined at line 135*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, num_shards: u8) !Metachain {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `num_shards` | `u8` | Num_shards |

**Returns:** `!Metachain`

*Defined at line 149*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *Metachain) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metachain` | The instance |

*Defined at line 165*

---

### `getHeight()`

Returns the current height.

```zig
pub fn getHeight(self: *const Metachain) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Metachain` | The instance |

**Returns:** `u64`

*Defined at line 171*

---

### `getLatestHash()`

Returns the current latest hash.

```zig
pub fn getLatestHash(self: *const Metachain) [32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Metachain` | The instance |

**Returns:** `[32]u8`

*Defined at line 175*

---

### `beginMetaBlock()`

Creează un nou MetaBlock gol pentru height-ul următor

```zig
pub fn beginMetaBlock(self: *Metachain) !*MetaBlock {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metachain` | The instance |

**Returns:** `!*MetaBlock`

*Defined at line 180*

---

### `finalizeMetaBlock()`

Finalizează MetaBlock-ul curent: calculează hash + procesează receipts pending

```zig
pub fn finalizeMetaBlock(self: *Metachain) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metachain` | The instance |

**Returns:** `!void`

*Defined at line 189*

---

### `printStatus()`

Performs the print status operation on the metachain module.

```zig
pub fn printStatus(self: *const Metachain) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Metachain` | The instance |

*Defined at line 257*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
