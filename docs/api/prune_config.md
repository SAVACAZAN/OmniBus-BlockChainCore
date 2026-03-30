# Module: `prune_config`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `PruneConfig`

Pruning configuration for blockchain size management

*Line: 4*

### `PruneStats`

Pruning statistics

*Line: 76*

### `RetentionPolicy`

Block retention policy

*Line: 121*

## Constants

| Name | Type | Value |
|------|------|-------|
| `PruneStrategy` | auto | `enum {` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) PruneConfig {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `PruneConfig`

*Line: 31*

---

### `estimateStorageSize`

Get estimated storage size based on config

```zig
pub fn estimateStorageSize(self: *const PruneConfig) u64 {
```

**Parameters:**

- `self`: `*const PruneConfig`

**Returns:** `u64`

*Line: 54*

---

### `validate`

Validate configuration

```zig
pub fn validate(self: *const PruneConfig) !void {
```

**Parameters:**

- `self`: `*const PruneConfig`

**Returns:** `!void`

*Line: 60*

---

### `print`

```zig
pub fn print(self: *const PruneStats) void {
```

**Parameters:**

- `self`: `*const PruneStats`

*Line: 84*

---

### `init`

```zig
pub fn init() RetentionPolicy {
```

**Returns:** `RetentionPolicy`

*Line: 127*

---

### `initByDays`

```zig
pub fn initByDays(days: u32) RetentionPolicy {
```

**Parameters:**

- `days`: `u32`

**Returns:** `RetentionPolicy`

*Line: 134*

---

### `initByCheckpoint`

```zig
pub fn initByCheckpoint(height: u32) RetentionPolicy {
```

**Parameters:**

- `height`: `u32`

**Returns:** `RetentionPolicy`

*Line: 141*

---

### `shouldKeepBlock`

```zig
pub fn shouldKeepBlock(self: *const RetentionPolicy, block_height: u32, total_blocks: u32) bool {
```

**Parameters:**

- `self`: `*const RetentionPolicy`
- `block_height`: `u32`
- `total_blocks`: `u32`

**Returns:** `bool`

*Line: 148*

---

