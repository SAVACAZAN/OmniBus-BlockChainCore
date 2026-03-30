# Module: `archive_manager`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `ArchiveManager`

Archive manager for storing pruned blocks

*Line: 4*

### `ArchiveMetadata`

Archive metadata

*Line: 98*

### `ArchiveSnapshot`

Archive snapshot

*Line: 119*

### `RestorableBlock`

Restorable block metadata

*Line: 134*

### `ArchiveIndex`

Archive index for quick lookup

*Line: 142*

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, archive_path: []const u8, compress: bool) ArchiveManager {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `archive_path`: `[]const u8`
- `compress`: `bool`

**Returns:** `ArchiveManager`

*Line: 11*

---

### `archiveBlocks`

Archive a batch of blocks

```zig
pub fn archiveBlocks(self: *ArchiveManager, start_height: u32, end_height: u32, blocks_data: []const u8) !void {
```

**Parameters:**

- `self`: `*ArchiveManager`
- `start_height`: `u32`
- `end_height`: `u32`
- `blocks_data`: `[]const u8`

**Returns:** `!void`

*Line: 20*

---

### `getArchiveMetadata`

Get archive metadata

```zig
pub fn getArchiveMetadata(self: *const ArchiveManager) ArchiveMetadata {
```

**Parameters:**

- `self`: `*const ArchiveManager`

**Returns:** `ArchiveMetadata`

*Line: 45*

---

### `createSnapshot`

Create archive snapshot

```zig
pub fn createSnapshot(self: *ArchiveManager, height: u32, hash: []const u8) !ArchiveSnapshot {
```

**Parameters:**

- `self`: `*ArchiveManager`
- `height`: `u32`
- `hash`: `[]const u8`

**Returns:** `!ArchiveSnapshot`

*Line: 54*

---

### `verifyArchive`

Verify archive integrity

```zig
pub fn verifyArchive(self: *const ArchiveManager) !bool {
```

**Parameters:**

- `self`: `*const ArchiveManager`

**Returns:** `!bool`

*Line: 64*

---

### `getRestorableBlocks`

Get list of restorable blocks

```zig
pub fn getRestorableBlocks(self: *ArchiveManager, allocator: std.mem.Allocator) ![]RestorableBlock {
```

**Parameters:**

- `self`: `*ArchiveManager`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]RestorableBlock`

*Line: 73*

---

### `deinit`

```zig
pub fn deinit(self: *ArchiveManager) void {
```

**Parameters:**

- `self`: `*ArchiveManager`

*Line: 92*

---

### `print`

```zig
pub fn print(self: *const ArchiveMetadata) void {
```

**Parameters:**

- `self`: `*const ArchiveMetadata`

*Line: 103*

---

### `print`

```zig
pub fn print(self: *const ArchiveSnapshot) void {
```

**Parameters:**

- `self`: `*const ArchiveSnapshot`

*Line: 125*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) ArchiveIndex {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `ArchiveIndex`

*Line: 146*

---

### `addSnapshot`

```zig
pub fn addSnapshot(self: *ArchiveIndex, snapshot: ArchiveSnapshot) !void {
```

**Parameters:**

- `self`: `*ArchiveIndex`
- `snapshot`: `ArchiveSnapshot`

**Returns:** `!void`

*Line: 153*

---

### `findByHeight`

```zig
pub fn findByHeight(self: *const ArchiveIndex, height: u32) ?ArchiveSnapshot {
```

**Parameters:**

- `self`: `*const ArchiveIndex`
- `height`: `u32`

**Returns:** `?ArchiveSnapshot`

*Line: 157*

---

### `deinit`

```zig
pub fn deinit(self: *ArchiveIndex) void {
```

**Parameters:**

- `self`: `*ArchiveIndex`

*Line: 166*

---

