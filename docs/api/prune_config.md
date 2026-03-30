# Module: `prune_config`

> Pruning configuration — configurable retention (max 10K blocks), auto-prune old data, reduce disk usage.

**Source:** `core/prune_config.zig` | **Lines:** 224 | **Functions:** 8 | **Structs:** 3 | **Tests:** 6

---

## Contents

### Structs
- [`PruneConfig`](#pruneconfig) — Pruning configuration for blockchain size management
- [`PruneStats`](#prunestats) — Pruning statistics
- [`RetentionPolicy`](#retentionpolicy) — Block retention policy

### Constants
- [1 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`estimateStorageSize()`](#estimatestoragesize) — Get estimated storage size based on config
- [`validate()`](#validate) — Validate configuration
- [`print()`](#print) — Performs the print operation on the prune_config module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`initByDays()`](#initbydays) — Performs the init by days operation on the prune_config module.
- [`initByCheckpoint()`](#initbycheckpoint) — Performs the init by checkpoint operation on the prune_config module.
- [`shouldKeepBlock()`](#shouldkeepblock) — Performs the should keep block operation on the prune_config module.

---

## Structs

### `PruneConfig`

Pruning configuration for blockchain size management

| Field | Type | Description |
|-------|------|-------------|
| `max_blocks_to_keep` | `u32` | Max_blocks_to_keep |
| `auto_prune_enabled` | `bool` | Auto_prune_enabled |
| `prune_threshold` | `u32` | Prune_threshold |
| `keep_days` | `u32` | Keep_days |
| `archive_enabled` | `bool` | Archive_enabled |
| `archive_path` | `[]const u8` | Archive_path |
| `compress_archived` | `bool` | Compress_archived |
| `keep_full_history` | `bool` | Keep_full_history |
| `allocator` | `std.mem.Allocator` | Allocator |
| `allocator` | `std.mem.Allocator` | Allocator |
| `max_blocks` | `u32` | Max_blocks |
| `keep_days` | `u32` | Keep_days |
| `archive_enabled` | `bool` | Archive_enabled |

*Defined at line 4*

---

### `PruneStats`

Pruning statistics

| Field | Type | Description |
|-------|------|-------------|
| `blocks_pruned` | `u32` | Blocks_pruned |
| `blocks_archived` | `u32` | Blocks_archived |
| `blocks_remaining` | `u32` | Blocks_remaining |
| `space_freed` | `u64` | Space_freed |
| `archive_size` | `u64` | Archive_size |
| `prune_count` | `u32` | Prune_count |

*Defined at line 76*

---

### `RetentionPolicy`

Block retention policy

| Field | Type | Description |
|-------|------|-------------|
| `strategy` | `PruneStrategy` | Strategy |
| `keep_count` | `u32` | Keep_count |
| `keep_days` | `u32` | Keep_days |
| `checkpoint_height` | `u32` | Checkpoint_height |

*Defined at line 121*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `PruneStrategy` | `enum {` | Prune strategy |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) PruneConfig {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `PruneConfig`

*Defined at line 31*

---

### `estimateStorageSize()`

Get estimated storage size based on config

```zig
pub fn estimateStorageSize(self: *const PruneConfig) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PruneConfig` | The instance |

**Returns:** `u64`

*Defined at line 54*

---

### `validate()`

Validate configuration

```zig
pub fn validate(self: *const PruneConfig) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PruneConfig` | The instance |

**Returns:** `!void`

*Defined at line 60*

---

### `print()`

Performs the print operation on the prune_config module.

```zig
pub fn print(self: *const PruneStats) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PruneStats` | The instance |

*Defined at line 84*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() RetentionPolicy {
```

**Returns:** `RetentionPolicy`

*Defined at line 127*

---

### `initByDays()`

Performs the init by days operation on the prune_config module.

```zig
pub fn initByDays(days: u32) RetentionPolicy {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `days` | `u32` | Days |

**Returns:** `RetentionPolicy`

*Defined at line 134*

---

### `initByCheckpoint()`

Performs the init by checkpoint operation on the prune_config module.

```zig
pub fn initByCheckpoint(height: u32) RetentionPolicy {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `height` | `u32` | Height |

**Returns:** `RetentionPolicy`

*Defined at line 141*

---

### `shouldKeepBlock()`

Performs the should keep block operation on the prune_config module.

```zig
pub fn shouldKeepBlock(self: *const RetentionPolicy, block_height: u32, total_blocks: u32) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const RetentionPolicy` | The instance |
| `block_height` | `u32` | Block_height |
| `total_blocks` | `u32` | Total_blocks |

**Returns:** `bool`

*Defined at line 148*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
