# Module: `sync`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `MsgGetHeaders`

Cerere: "am blocuri pana la height X, trimite-mi de la X+1"

*Line: 16*

### `BlockHeader`

Un header compact de bloc pentru sync rapid (fara TX-uri)
88 bytes per header

*Line: 38*

### `MsgHeaders`

Raspuns la GetHeaders: lista de headere compacte

*Line: 90*

### `MsgBlocks`

Raspuns cu blocuri complete: [count:2][header0:88][header1:88]...
Acelasi format ca MsgHeaders dar semnifica blocuri descarcate complet

*Line: 124*

### `MsgGetBlocks`

Cerere blocuri complete dupa height

*Line: 157*

### `SyncState`

*Line: 186*

### `SyncManager`

*Line: 230*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Blockchain` | auto | `blockchain_mod.Blockchain` |
| `Block` | auto | `block_mod.Block` |
| `SyncStatus` | auto | `enum {` |
| `MAX_HEADERS_PER_REQ` | auto | `u16 = 2000` |
| `MAX_BLOCKS_PER_REQ` | auto | `u16 = 128` |

## Functions

### `encode`

```zig
pub fn encode(self: MsgGetHeaders) [10]u8 {
```

**Parameters:**

- `self`: `MsgGetHeaders`

**Returns:** `[10]u8`

*Line: 20*

---

### `decode`

```zig
pub fn decode(buf: []const u8) ?MsgGetHeaders {
```

**Parameters:**

- `buf`: `[]const u8`

**Returns:** `?MsgGetHeaders`

*Line: 27*

---

### `fromBlock`

```zig
pub fn fromBlock(b: *const Block, height: u64) BlockHeader {
```

**Parameters:**

- `b`: `*const Block`
- `height`: `u64`

**Returns:** `BlockHeader`

*Line: 45*

---

### `encode`

```zig
pub fn encode(self: BlockHeader, buf: *[88]u8) void {
```

**Parameters:**

- `self`: `BlockHeader`
- `buf`: `*[88]u8`

*Line: 65*

---

### `decode`

```zig
pub fn decode(buf: []const u8) ?BlockHeader {
```

**Parameters:**

- `buf`: `[]const u8`

**Returns:** `?BlockHeader`

*Line: 73*

---

### `encode`

Encode: [count:2][header0:88][header1:88]...

```zig
pub fn encode(self: MsgHeaders, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `MsgHeaders`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 95*

---

### `decode`

```zig
pub fn decode(buf: []const u8, allocator: std.mem.Allocator) !MsgHeaders {
```

**Parameters:**

- `buf`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!MsgHeaders`

*Line: 107*

---

### `encode`

Encode: [count:2][header0:88][header1:88]...

```zig
pub fn encode(self: MsgBlocks, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `MsgBlocks`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 129*

---

### `decode`

```zig
pub fn decode(buf: []const u8, allocator: std.mem.Allocator) !MsgBlocks {
```

**Parameters:**

- `buf`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!MsgBlocks`

*Line: 141*

---

### `encode`

```zig
pub fn encode(self: MsgGetBlocks) [10]u8 {
```

**Parameters:**

- `self`: `MsgGetBlocks`

**Returns:** `[10]u8`

*Line: 161*

---

### `decode`

```zig
pub fn decode(buf: []const u8) ?MsgGetBlocks {
```

**Parameters:**

- `buf`: `[]const u8`

**Returns:** `?MsgGetBlocks`

*Line: 168*

---

### `init`

```zig
pub fn init(local_height: u64) SyncState {
```

**Parameters:**

- `local_height`: `u64`

**Returns:** `SyncState`

*Line: 194*

---

### `isBehind`

```zig
pub fn isBehind(self: *const SyncState) bool {
```

**Parameters:**

- `self`: `*const SyncState`

**Returns:** `bool`

*Line: 205*

---

### `progressPct`

```zig
pub fn progressPct(self: *const SyncState) f64 {
```

**Parameters:**

- `self`: `*const SyncState`

**Returns:** `f64`

*Line: 209*

---

### `print`

```zig
pub fn print(self: *const SyncState) void {
```

**Parameters:**

- `self`: `*const SyncState`

*Line: 215*

---

### `init`

```zig
pub fn init(local_height: u64, allocator: std.mem.Allocator) SyncManager {
```

**Parameters:**

- `local_height`: `u64`
- `allocator`: `std.mem.Allocator`

**Returns:** `SyncManager`

*Line: 239*

---

### `onPeerHeight`

Notifica ca un peer are height mai mare
Returneaza GetHeaders encodat daca trebuie sa sincronizam

```zig
pub fn onPeerHeight(self: *SyncManager, peer_height: u64) ?[10]u8 {
```

**Parameters:**

- `self`: `*SyncManager`
- `peer_height`: `u64`

**Returns:** `?[10]u8`

*Line: 248*

---

### `onBlockApplied`

Notifica ca un bloc nou a fost primit si validat

```zig
pub fn onBlockApplied(self: *SyncManager, new_height: u64) void {
```

**Parameters:**

- `self`: `*SyncManager`
- `new_height`: `u64`

*Line: 329*

---

### `onBlocksReceived`

Proceseaza un batch de blocuri primite:
- actualizeaza local_height cu count blocuri noi
- actualizeaza last_progress
- trece in .synced daca am ajuns la peer_height

```zig
pub fn onBlocksReceived(self: *SyncManager, count: u32) void {
```

**Parameters:**

- `self`: `*SyncManager`
- `count`: `u32`

*Line: 346*

---

### `retryIfStalled`

Daca sync-ul e blocat (isStalled), reseteaza la .requesting pentru retry.
Returneaza true daca s-a facut retry.

```zig
pub fn retryIfStalled(self: *SyncManager) bool {
```

**Parameters:**

- `self`: `*SyncManager`

**Returns:** `bool`

*Line: 367*

---

### `isStalled`

Verifica daca sync-ul a blocat (>60s fara progres)

```zig
pub fn isStalled(self: *const SyncManager) bool {
```

**Parameters:**

- `self`: `*const SyncManager`

**Returns:** `bool`

*Line: 377*

---

### `isSynced`

```zig
pub fn isSynced(self: *const SyncManager) bool {
```

**Parameters:**

- `self`: `*const SyncManager`

**Returns:** `bool`

*Line: 383*

---

