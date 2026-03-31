# Module: `shard_config`

> Shard configuration — 7-way sharding parameters, load thresholds, shard assignment rules.

**Source:** `core/shard_config.zig` | **Lines:** 191 | **Functions:** 11 | **Structs:** 3 | **Tests:** 4

---

## Contents

### Structs
- [`ShardConfig`](#shardconfig) — Shard configuration for distributed sub-block processing
- [`ShardInfo`](#shardinfo) — Information about a single shard
- [`ShardValidator`](#shardvalidator) — Shard assignment validator

### Constants
- [1 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`getShardForSubBlock()`](#getshardforsubblock) — Calculate which shard should process a sub-block
- [`shouldProcessSubBlock()`](#shouldprocesssubblock) — Check if this node should process the sub-block
- [`getSubBlocksForShard()`](#getsubblocksforshard) — Get all sub-block IDs this shard processes
- [`getDistribution()`](#getdistribution) — Get shard distribution info
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`validateSubBlockShard()`](#validatesubblockshard) — Validate that sub-block was processed by correct shard
- [`recordProcessed()`](#recordprocessed) — Track processed sub-blocks for this node's shard
- [`blockComplete()`](#blockcomplete) — Check if all sub-blocks for this shard in a block have been processed
- [`reset()`](#reset) — Reset for next block
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.

---

## Structs

### `ShardConfig`

Shard configuration for distributed sub-block processing

| Field | Type | Description |
|-------|------|-------------|
| `num_shards` | `u8` | Num_shards |
| `current_node_shard` | `u8` | Current_node_shard |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 7*

---

### `ShardInfo`

Information about a single shard

| Field | Type | Description |
|-------|------|-------------|
| `shard_id` | `u8` | Shard_id |
| `sub_block_count` | `u8` | Sub_block_count |
| `sub_block_ids` | `[]u8` | Sub_block_ids |

*Defined at line 77*

---

### `ShardValidator`

Shard assignment validator

| Field | Type | Description |
|-------|------|-------------|
| `config` | `ShardConfig` | Config |
| `processed_sub_blocks` | `std.array_list.Managed(u8)` | Processed_sub_blocks |

*Defined at line 84*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `SubBlock` | `sub_block_mod.SubBlock` | Sub block |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, current_node_shard: u8) !ShardConfig {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `current_node_shard` | `u8` | Current_node_shard |

**Returns:** `!ShardConfig`

*Defined at line 12*

---

### `getShardForSubBlock()`

Calculate which shard should process a sub-block

```zig
pub fn getShardForSubBlock(self: *const ShardConfig, sub_id: u8) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardConfig` | The instance |
| `sub_id` | `u8` | Sub_id |

**Returns:** `u8`

*Defined at line 25*

---

### `shouldProcessSubBlock()`

Check if this node should process the sub-block

```zig
pub fn shouldProcessSubBlock(self: *const ShardConfig, sub_id: u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardConfig` | The instance |
| `sub_id` | `u8` | Sub_id |

**Returns:** `bool`

*Defined at line 30*

---

### `getSubBlocksForShard()`

Get all sub-block IDs this shard processes

```zig
pub fn getSubBlocksForShard(self: *const ShardConfig, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardConfig` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 35*

---

### `getDistribution()`

Get shard distribution info

```zig
pub fn getDistribution(self: *const ShardConfig, allocator: std.mem.Allocator) ![7]ShardInfo {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardConfig` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![7]ShardInfo`

*Defined at line 49*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(config: ShardConfig) ShardValidator {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `config` | `ShardConfig` | Config |

**Returns:** `ShardValidator`

*Defined at line 88*

---

### `validateSubBlockShard()`

Validate that sub-block was processed by correct shard

```zig
pub fn validateSubBlockShard(self: *const ShardValidator, sub: *const SubBlock) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardValidator` | The instance |
| `sub` | `*const SubBlock` | Sub |

**Returns:** `!bool`

*Defined at line 96*

---

### `recordProcessed()`

Track processed sub-blocks for this node's shard

```zig
pub fn recordProcessed(self: *ShardValidator, sub_id: u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ShardValidator` | The instance |
| `sub_id` | `u8` | Sub_id |

**Returns:** `!void`

*Defined at line 105*

---

### `blockComplete()`

Check if all sub-blocks for this shard in a block have been processed

```zig
pub fn blockComplete(self: *const ShardValidator) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardValidator` | The instance |

**Returns:** `bool`

*Defined at line 114*

---

### `reset()`

Reset for next block

```zig
pub fn reset(self: *ShardValidator) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ShardValidator` | The instance |

*Defined at line 128*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *ShardValidator) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ShardValidator` | The instance |

*Defined at line 132*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
