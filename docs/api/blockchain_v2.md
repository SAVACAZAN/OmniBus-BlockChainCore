# Module: `blockchain_v2`

> Enhanced blockchain v2 — sub-block support, sharding integration, binary encoding, pruning support.

**Source:** `core/blockchain_v2.zig` | **Lines:** 541 | **Functions:** 20 | **Structs:** 2 | **Tests:** 22

---

## Contents

### Structs
- [`BlockchainV2`](#blockchainv2) — Blockchain v2 - with sub-blocks, sharding, and pruning support
- [`BlockStats`](#blockstats) — Data structure for block stats. Fields include: block_count, transaction_count, ...

### Constants
- [10 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`initWithPruning()`](#initwithpruning) — Performs the init with pruning operation on the blockchain_v2 module.
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`addTransaction()`](#addtransaction) — Add transaction to mempool
- [`validateTransaction()`](#validatetransaction) — Validate transaction (delegates to Transaction.isValid + hash integrit...
- [`createSubBlock()`](#createsubblock) — Create sub-block (0.1s interval)
- [`addSubBlock()`](#addsubblock) — Add sub-block via engine
- [`isSubBlockPoolComplete()`](#issubblockpoolcomplete) — Check if all 10 sub-blocks are collected
- [`createBlockFromSubBlocks()`](#createblockfromsubblocks) — Create main block from complete sub-block pool
- [`mineBlock()`](#mineblock) — Mine block (simple PoW)
- [`calculateBlockHash()`](#calculateblockhash) — Calculate block hash (shared implementation in hex_utils)
- [`isValidHash()`](#isvalidhash) — Validate hash meets difficulty (delegates to shared hex_utils)
- [`encodeBlockBinary()`](#encodeblockbinary) — Encode block to binary format (93% compression)
- [`getStats()`](#getstats) — Get blockchain statistics
- [`getBlockCount()`](#getblockcount) — Returns the current block count.
- [`pruneOldBlocks()`](#pruneoldblocks) — Prune old blocks based on configuration
- [`needsPruning()`](#needspruning) — Check if pruning is needed
- [`getPruneStats()`](#getprunestats) — Get pruning statistics
- [`getEstimatedStorageSize()`](#getestimatedstoragesize) — Get estimated storage size
- [`printInfo()`](#printinfo) — Print blockchain info including pruning stats

---

## Structs

### `BlockchainV2`

Blockchain v2 - with sub-blocks, sharding, and pruning support

| Field | Type | Description |
|-------|------|-------------|
| `chain` | `array_list.Managed(Block)` | Chain |
| `mempool` | `array_list.Managed(Transaction)` | Mempool |
| `sub_block_engine` | `SubBlockEngine` | Sub_block_engine |
| `shard_config` | `ShardConfig` | Shard_config |
| `prune_config` | `PruneConfig` | Prune_config |
| `archive_mgr` | `?ArchiveManager` | Archive_mgr |

*Defined at line 24*

---

### `BlockStats`

Data structure for block stats. Fields include: block_count, transaction_count, sub_blocks_pending, difficulty, shard_id.

| Field | Type | Description |
|-------|------|-------------|
| `block_count` | `usize` | Block_count |
| `transaction_count` | `usize` | Transaction_count |
| `sub_blocks_pending` | `u8` | Sub_blocks_pending |
| `difficulty` | `u32` | Difficulty |
| `shard_id` | `u8` | Shard_id |

*Defined at line 337*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `Block` | `block_mod.Block` | Block |
| `Transaction` | `transaction_mod.Transaction` | Transaction |
| `SubBlock` | `sub_block_mod.SubBlock` | Sub block |
| `SubBlockEngine` | `sub_block_mod.SubBlockEngine` | Sub block engine |
| `ShardConfig` | `shard_config.ShardConfig` | Shard config |
| `BinaryEncoder` | `binary_codec.BinaryEncoder` | Binary encoder |
| `BinaryDecoder` | `binary_codec.BinaryDecoder` | Binary decoder |
| `PruneConfig` | `prune_config.PruneConfig` | Prune config |
| `PruneStats` | `prune_config.PruneStats` | Prune stats |
| `ArchiveManager` | `archive_manager_mod.ArchiveManager` | Archive manager |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, shard_id: u8) !BlockchainV2 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `shard_id` | `u8` | Shard_id |

**Returns:** `!BlockchainV2`

*Defined at line 36*

---

### `initWithPruning()`

Performs the init with pruning operation on the blockchain_v2 module.

```zig
pub fn initWithPruning(allocator: std.mem.Allocator, shard_id: u8, prune_cfg: PruneConfig) !BlockchainV2 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `shard_id` | `u8` | Shard_id |
| `prune_cfg` | `PruneConfig` | Prune_cfg |

**Returns:** `!BlockchainV2`

*Defined at line 40*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *BlockchainV2) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |

*Defined at line 81*

---

### `addTransaction()`

Add transaction to mempool

```zig
pub fn addTransaction(self: *BlockchainV2, tx: Transaction) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |
| `tx` | `Transaction` | Tx |

**Returns:** `!void`

*Defined at line 94*

---

### `validateTransaction()`

Validate transaction (delegates to Transaction.isValid + hash integrity)

```zig
pub fn validateTransaction(self: *BlockchainV2, tx: *const Transaction) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |
| `tx` | `*const Transaction` | Tx |

**Returns:** `!bool`

*Defined at line 102*

---

### `createSubBlock()`

Create sub-block (0.1s interval)

```zig
pub fn createSubBlock(self: *BlockchainV2, sub_id: u8, miner_id: []const u8) !SubBlock {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |
| `sub_id` | `u8` | Sub_id |
| `miner_id` | `[]const u8` | Miner_id |

**Returns:** `!SubBlock`

*Defined at line 116*

---

### `addSubBlock()`

Add sub-block via engine

```zig
pub fn addSubBlock(self: *BlockchainV2, sub: SubBlock) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |
| `sub` | `SubBlock` | Sub |

**Returns:** `!void`

*Defined at line 138*

---

### `isSubBlockPoolComplete()`

Check if all 10 sub-blocks are collected

```zig
pub fn isSubBlockPoolComplete(self: *const BlockchainV2) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockchainV2` | The instance |

**Returns:** `bool`

*Defined at line 145*

---

### `createBlockFromSubBlocks()`

Create main block from complete sub-block pool

```zig
pub fn createBlockFromSubBlocks(self: *BlockchainV2) !Block {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |

**Returns:** `!Block`

*Defined at line 150*

---

### `mineBlock()`

Mine block (simple PoW)

```zig
pub fn mineBlock(self: *BlockchainV2, block: *Block) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |
| `block` | `*Block` | Block |

**Returns:** `!void`

*Defined at line 186*

---

### `calculateBlockHash()`

Calculate block hash (shared implementation in hex_utils)

```zig
pub fn calculateBlockHash(self: *BlockchainV2, block: *const Block) ![]const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |
| `block` | `*const Block` | Block |

**Returns:** `![]const u8`

*Defined at line 205*

---

### `isValidHash()`

Validate hash meets difficulty (delegates to shared hex_utils)

```zig
pub fn isValidHash(self: *BlockchainV2, hash: []const u8) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |
| `hash` | `[]const u8` | Hash |

**Returns:** `!bool`

*Defined at line 210*

---

### `encodeBlockBinary()`

Encode block to binary format (93% compression)

```zig
pub fn encodeBlockBinary(self: *BlockchainV2, block: *const Block) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |
| `block` | `*const Block` | Block |

**Returns:** `![]u8`

*Defined at line 215*

---

### `getStats()`

Get blockchain statistics

```zig
pub fn getStats(self: *const BlockchainV2) BlockStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockchainV2` | The instance |

**Returns:** `BlockStats`

*Defined at line 238*

---

### `getBlockCount()`

Returns the current block count.

```zig
pub fn getBlockCount(self: *const BlockchainV2) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockchainV2` | The instance |

**Returns:** `u32`

*Defined at line 248*

---

### `pruneOldBlocks()`

Prune old blocks based on configuration

```zig
pub fn pruneOldBlocks(self: *BlockchainV2) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockchainV2` | The instance |

**Returns:** `!void`

*Defined at line 253*

---

### `needsPruning()`

Check if pruning is needed

```zig
pub fn needsPruning(self: *const BlockchainV2) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockchainV2` | The instance |

**Returns:** `bool`

*Defined at line 297*

---

### `getPruneStats()`

Get pruning statistics

```zig
pub fn getPruneStats(self: *const BlockchainV2) PruneStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockchainV2` | The instance |

**Returns:** `PruneStats`

*Defined at line 302*

---

### `getEstimatedStorageSize()`

Get estimated storage size

```zig
pub fn getEstimatedStorageSize(self: *const BlockchainV2) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockchainV2` | The instance |

**Returns:** `u64`

*Defined at line 307*

---

### `printInfo()`

Print blockchain info including pruning stats

```zig
pub fn printInfo(self: *const BlockchainV2) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockchainV2` | The instance |

*Defined at line 313*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
