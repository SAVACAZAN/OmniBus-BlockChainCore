# Module: `shard_config`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `ShardConfig`

Shard configuration for distributed sub-block processing

*Line: 7*

### `ShardInfo`

Information about a single shard

*Line: 77*

### `ShardValidator`

Shard assignment validator

*Line: 84*

## Constants

| Name | Type | Value |
|------|------|-------|
| `SubBlock` | auto | `sub_block_mod.SubBlock` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, current_node_shard: u8) !ShardConfig {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `current_node_shard`: `u8`

**Returns:** `!ShardConfig`

*Line: 12*

---

### `getShardForSubBlock`

Calculate which shard should process a sub-block

```zig
pub fn getShardForSubBlock(self: *const ShardConfig, sub_id: u8) u8 {
```

**Parameters:**

- `self`: `*const ShardConfig`
- `sub_id`: `u8`

**Returns:** `u8`

*Line: 25*

---

### `shouldProcessSubBlock`

Check if this node should process the sub-block

```zig
pub fn shouldProcessSubBlock(self: *const ShardConfig, sub_id: u8) bool {
```

**Parameters:**

- `self`: `*const ShardConfig`
- `sub_id`: `u8`

**Returns:** `bool`

*Line: 30*

---

### `getSubBlocksForShard`

Get all sub-block IDs this shard processes

```zig
pub fn getSubBlocksForShard(self: *const ShardConfig, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const ShardConfig`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 35*

---

### `getDistribution`

Get shard distribution info

```zig
pub fn getDistribution(self: *const ShardConfig, allocator: std.mem.Allocator) ![7]ShardInfo {
```

**Parameters:**

- `self`: `*const ShardConfig`
- `allocator`: `std.mem.Allocator`

**Returns:** `![7]ShardInfo`

*Line: 49*

---

### `init`

```zig
pub fn init(config: ShardConfig) ShardValidator {
```

**Parameters:**

- `config`: `ShardConfig`

**Returns:** `ShardValidator`

*Line: 88*

---

### `validateSubBlockShard`

Validate that sub-block was processed by correct shard

```zig
pub fn validateSubBlockShard(self: *const ShardValidator, sub: *const SubBlock) !bool {
```

**Parameters:**

- `self`: `*const ShardValidator`
- `sub`: `*const SubBlock`

**Returns:** `!bool`

*Line: 96*

---

### `recordProcessed`

Track processed sub-blocks for this node's shard

```zig
pub fn recordProcessed(self: *ShardValidator, sub_id: u8) !void {
```

**Parameters:**

- `self`: `*ShardValidator`
- `sub_id`: `u8`

**Returns:** `!void`

*Line: 105*

---

### `blockComplete`

Check if all sub-blocks for this shard in a block have been processed

```zig
pub fn blockComplete(self: *const ShardValidator) bool {
```

**Parameters:**

- `self`: `*const ShardValidator`

**Returns:** `bool`

*Line: 114*

---

### `reset`

Reset for next block

```zig
pub fn reset(self: *ShardValidator) void {
```

**Parameters:**

- `self`: `*ShardValidator`

*Line: 128*

---

### `deinit`

```zig
pub fn deinit(self: *ShardValidator) void {
```

**Parameters:**

- `self`: `*ShardValidator`

*Line: 132*

---

