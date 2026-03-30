# Module: `blockchain_v2`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `BlockchainV2`

Blockchain v2 - with sub-blocks, sharding, and pruning support

*Line: 24*

### `BlockStats`

*Line: 339*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Block` | auto | `block_mod.Block` |
| `Transaction` | auto | `transaction_mod.Transaction` |
| `SubBlock` | auto | `sub_block_mod.SubBlock` |
| `SubBlockEngine` | auto | `sub_block_mod.SubBlockEngine` |
| `ShardConfig` | auto | `shard_config.ShardConfig` |
| `BinaryEncoder` | auto | `binary_codec.BinaryEncoder` |
| `BinaryDecoder` | auto | `binary_codec.BinaryDecoder` |
| `PruneConfig` | auto | `prune_config.PruneConfig` |
| `PruneStats` | auto | `prune_config.PruneStats` |
| `ArchiveManager` | auto | `archive_manager_mod.ArchiveManager` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, shard_id: u8) !BlockchainV2 {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `shard_id`: `u8`

**Returns:** `!BlockchainV2`

*Line: 36*

---

### `initWithPruning`

```zig
pub fn initWithPruning(allocator: std.mem.Allocator, shard_id: u8, prune_cfg: PruneConfig) !BlockchainV2 {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `shard_id`: `u8`
- `prune_cfg`: `PruneConfig`

**Returns:** `!BlockchainV2`

*Line: 40*

---

### `deinit`

```zig
pub fn deinit(self: *BlockchainV2) void {
```

**Parameters:**

- `self`: `*BlockchainV2`

*Line: 81*

---

### `addTransaction`

Add transaction to mempool

```zig
pub fn addTransaction(self: *BlockchainV2, tx: Transaction) !void {
```

**Parameters:**

- `self`: `*BlockchainV2`
- `tx`: `Transaction`

**Returns:** `!void`

*Line: 94*

---

### `validateTransaction`

Validate transaction

```zig
pub fn validateTransaction(self: *BlockchainV2, tx: *const Transaction) !bool {
```

**Parameters:**

- `self`: `*BlockchainV2`
- `tx`: `*const Transaction`

**Returns:** `!bool`

*Line: 102*

---

### `createSubBlock`

Create sub-block (0.1s interval)

```zig
pub fn createSubBlock(self: *BlockchainV2, sub_id: u8, miner_id: []const u8) !SubBlock {
```

**Parameters:**

- `self`: `*BlockchainV2`
- `sub_id`: `u8`
- `miner_id`: `[]const u8`

**Returns:** `!SubBlock`

*Line: 110*

---

### `addSubBlock`

Add sub-block via engine

```zig
pub fn addSubBlock(self: *BlockchainV2, sub: SubBlock) !void {
```

**Parameters:**

- `self`: `*BlockchainV2`
- `sub`: `SubBlock`

**Returns:** `!void`

*Line: 132*

---

### `isSubBlockPoolComplete`

Check if all 10 sub-blocks are collected

```zig
pub fn isSubBlockPoolComplete(self: *const BlockchainV2) bool {
```

**Parameters:**

- `self`: `*const BlockchainV2`

**Returns:** `bool`

*Line: 139*

---

### `createBlockFromSubBlocks`

Create main block from complete sub-block pool

```zig
pub fn createBlockFromSubBlocks(self: *BlockchainV2) !Block {
```

**Parameters:**

- `self`: `*BlockchainV2`

**Returns:** `!Block`

*Line: 144*

---

### `mineBlock`

Mine block (simple PoW)

```zig
pub fn mineBlock(self: *BlockchainV2, block: *Block) !void {
```

**Parameters:**

- `self`: `*BlockchainV2`
- `block`: `*Block`

**Returns:** `!void`

*Line: 180*

---

### `calculateBlockHash`

Calculate block hash (delegates to shared hex_utils — eliminates duplication)

```zig
pub fn calculateBlockHash(self: *BlockchainV2, block: *const Block) ![]const u8 {
```

**Parameters:**

- `self`: `*BlockchainV2`
- `block`: `*const Block`

**Returns:** `![]const u8`

*Line: 199*

---

### `isValidHash`

Validate hash meets difficulty (delegates to shared hex_utils)

```zig
pub fn isValidHash(self: *BlockchainV2, hash: []const u8) !bool {
```

**Parameters:**

- `self`: `*BlockchainV2`
- `hash`: `[]const u8`

**Returns:** `!bool`

*Line: 212*

---

### `encodeBlockBinary`

Encode block to binary format (93% compression)

```zig
pub fn encodeBlockBinary(self: *BlockchainV2, block: *const Block) ![]u8 {
```

**Parameters:**

- `self`: `*BlockchainV2`
- `block`: `*const Block`

**Returns:** `![]u8`

*Line: 217*

---

### `getStats`

Get blockchain statistics

```zig
pub fn getStats(self: *const BlockchainV2) BlockStats {
```

**Parameters:**

- `self`: `*const BlockchainV2`

**Returns:** `BlockStats`

*Line: 240*

---

### `getBlockCount`

```zig
pub fn getBlockCount(self: *const BlockchainV2) u32 {
```

**Parameters:**

- `self`: `*const BlockchainV2`

**Returns:** `u32`

*Line: 250*

---

### `pruneOldBlocks`

Prune old blocks based on configuration

```zig
pub fn pruneOldBlocks(self: *BlockchainV2) !void {
```

**Parameters:**

- `self`: `*BlockchainV2`

**Returns:** `!void`

*Line: 255*

---

### `needsPruning`

Check if pruning is needed

```zig
pub fn needsPruning(self: *const BlockchainV2) bool {
```

**Parameters:**

- `self`: `*const BlockchainV2`

**Returns:** `bool`

*Line: 299*

---

### `getPruneStats`

Get pruning statistics

```zig
pub fn getPruneStats(self: *const BlockchainV2) PruneStats {
```

**Parameters:**

- `self`: `*const BlockchainV2`

**Returns:** `PruneStats`

*Line: 304*

---

### `getEstimatedStorageSize`

Get estimated storage size

```zig
pub fn getEstimatedStorageSize(self: *const BlockchainV2) u64 {
```

**Parameters:**

- `self`: `*const BlockchainV2`

**Returns:** `u64`

*Line: 309*

---

### `printInfo`

Print blockchain info including pruning stats

```zig
pub fn printInfo(self: *const BlockchainV2) void {
```

**Parameters:**

- `self`: `*const BlockchainV2`

*Line: 315*

---

