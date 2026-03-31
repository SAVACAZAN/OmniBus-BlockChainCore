# Module: `archive_manager`

> Block archival — compress old blocks for long-term storage, retrieve archived blocks on demand.

**Source:** `core/archive_manager.zig` | **Lines:** 224 | **Functions:** 13 | **Structs:** 5 | **Tests:** 5

---

## Contents

### Structs
- [`ArchiveManager`](#archivemanager) — Archive manager for storing pruned blocks
- [`ArchiveMetadata`](#archivemetadata) — Archive metadata
- [`ArchiveSnapshot`](#archivesnapshot) — Archive snapshot
- [`RestorableBlock`](#restorableblock) — Restorable block metadata
- [`ArchiveIndex`](#archiveindex) — Archive index for quick lookup

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`archiveBlocks()`](#archiveblocks) — Archive a batch of blocks
- [`getArchiveMetadata()`](#getarchivemetadata) — Get archive metadata
- [`createSnapshot()`](#createsnapshot) — Create archive snapshot
- [`verifyArchive()`](#verifyarchive) — Verify archive integrity
- [`getRestorableBlocks()`](#getrestorableblocks) — Get list of restorable blocks
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`print()`](#print) — Performs the print operation on the archive_manager module.
- [`print()`](#print) — Performs the print operation on the archive_manager module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addSnapshot()`](#addsnapshot) — Adds a new snapshot to the collection.
- [`findByHeight()`](#findbyheight) — Searches for by height matching the given criteria.
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.

---

## Structs

### `ArchiveManager`

Archive manager for storing pruned blocks

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `archive_path` | `[]const u8` | Archive_path |
| `compress_enabled` | `bool` | Compress_enabled |
| `archived_blocks` | `u32` | Archived_blocks |
| `total_archive_size` | `u64` | Total_archive_size |

*Defined at line 4*

---

### `ArchiveMetadata`

Archive metadata

| Field | Type | Description |
|-------|------|-------------|
| `archived_block_count` | `u32` | Archived_block_count |
| `total_size_bytes` | `u64` | Total_size_bytes |
| `estimated_restore_time_sec` | `u64` | Estimated_restore_time_sec |

*Defined at line 98*

---

### `ArchiveSnapshot`

Archive snapshot

| Field | Type | Description |
|-------|------|-------------|
| `height` | `u32` | Height |
| `block_hash` | `[]const u8` | Block_hash |
| `created_at` | `i64` | Created_at |
| `archive_size` | `u64` | Archive_size |

*Defined at line 119*

---

### `RestorableBlock`

Restorable block metadata

| Field | Type | Description |
|-------|------|-------------|
| `start_height` | `u32` | Start_height |
| `end_height` | `u32` | End_height |
| `size_bytes` | `u64` | Size_bytes |
| `created_at` | `i64` | Created_at |

*Defined at line 134*

---

### `ArchiveIndex`

Archive index for quick lookup

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `snapshots` | `std.array_list.Managed(ArchiveSnapshot)` | Snapshots |

*Defined at line 142*

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, archive_path: []const u8, compress: bool) ArchiveManager {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `archive_path` | `[]const u8` | Archive_path |
| `compress` | `bool` | Compress |

**Returns:** `ArchiveManager`

*Defined at line 11*

---

### `archiveBlocks()`

Archive a batch of blocks

```zig
pub fn archiveBlocks(self: *ArchiveManager, start_height: u32, end_height: u32, blocks_data: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ArchiveManager` | The instance |
| `start_height` | `u32` | Start_height |
| `end_height` | `u32` | End_height |
| `blocks_data` | `[]const u8` | Blocks_data |

**Returns:** `!void`

*Defined at line 20*

---

### `getArchiveMetadata()`

Get archive metadata

```zig
pub fn getArchiveMetadata(self: *const ArchiveManager) ArchiveMetadata {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ArchiveManager` | The instance |

**Returns:** `ArchiveMetadata`

*Defined at line 45*

---

### `createSnapshot()`

Create archive snapshot

```zig
pub fn createSnapshot(self: *ArchiveManager, height: u32, hash: []const u8) !ArchiveSnapshot {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ArchiveManager` | The instance |
| `height` | `u32` | Height |
| `hash` | `[]const u8` | Hash |

**Returns:** `!ArchiveSnapshot`

*Defined at line 54*

---

### `verifyArchive()`

Verify archive integrity

```zig
pub fn verifyArchive(self: *const ArchiveManager) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ArchiveManager` | The instance |

**Returns:** `!bool`

*Defined at line 64*

---

### `getRestorableBlocks()`

Get list of restorable blocks

```zig
pub fn getRestorableBlocks(self: *ArchiveManager, allocator: std.mem.Allocator) ![]RestorableBlock {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ArchiveManager` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]RestorableBlock`

*Defined at line 73*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *ArchiveManager) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ArchiveManager` | The instance |

*Defined at line 92*

---

### `print()`

Performs the print operation on the archive_manager module.

```zig
pub fn print(self: *const ArchiveMetadata) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ArchiveMetadata` | The instance |

*Defined at line 103*

---

### `print()`

Performs the print operation on the archive_manager module.

```zig
pub fn print(self: *const ArchiveSnapshot) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ArchiveSnapshot` | The instance |

*Defined at line 125*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) ArchiveIndex {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `ArchiveIndex`

*Defined at line 146*

---

### `addSnapshot()`

Adds a new snapshot to the collection.

```zig
pub fn addSnapshot(self: *ArchiveIndex, snapshot: ArchiveSnapshot) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ArchiveIndex` | The instance |
| `snapshot` | `ArchiveSnapshot` | Snapshot |

**Returns:** `!void`

*Defined at line 153*

---

### `findByHeight()`

Searches for by height matching the given criteria.

```zig
pub fn findByHeight(self: *const ArchiveIndex, height: u32) ?ArchiveSnapshot {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ArchiveIndex` | The instance |
| `height` | `u32` | Height |

**Returns:** `?ArchiveSnapshot`

*Defined at line 157*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *ArchiveIndex) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ArchiveIndex` | The instance |

*Defined at line 166*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
