# Module: `sync`

> Block synchronization — header-first sync, block download, stall detection, fork resolution, and chain reorganization.

**Source:** `core/sync.zig` | **Lines:** 638 | **Functions:** 22 | **Structs:** 7 | **Tests:** 12

---

## Contents

### Structs
- [`MsgGetHeaders`](#msggetheaders) — Cerere: "am blocuri pana la height X, trimite-mi de la X+1"
- [`BlockHeader`](#blockheader) — Un header compact de bloc pentru sync rapid (fara TX-uri)
88 bytes per header
- [`MsgHeaders`](#msgheaders) — Raspuns la GetHeaders: lista de headere compacte
- [`MsgBlocks`](#msgblocks) — Raspuns cu blocuri complete: [count:2][header0:88][header1:88]...
Acelasi format...
- [`MsgGetBlocks`](#msggetblocks) — Cerere blocuri complete dupa height
- [`SyncState`](#syncstate) — Data structure for sync state. Fields include: status, local_height, peer_height...
- [`SyncManager`](#syncmanager) — Data structure for sync manager. Fields include: state, allocator.

### Constants
- [5 constants defined](#constants)

### Functions
- [`encode()`](#encode) — Decodes the encoded data back to its original format.
- [`decode()`](#decode) — Attempts to find decode. Returns null if not found.
- [`fromBlock()`](#fromblock) — Performs the from block operation on the sync module.
- [`encode()`](#encode) — Decodes the encoded data back to its original format.
- [`decode()`](#decode) — Attempts to find decode. Returns null if not found.
- [`encode()`](#encode) — Encode: [count:2][header0:88][header1:88]...
- [`decode()`](#decode) — Performs the decode operation on the sync module.
- [`encode()`](#encode) — Encode: [count:2][header0:88][header1:88]...
- [`decode()`](#decode) — Performs the decode operation on the sync module.
- [`encode()`](#encode) — Decodes the encoded data back to its original format.
- [`decode()`](#decode) — Attempts to find decode. Returns null if not found.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`isBehind()`](#isbehind) — Checks whether the behind condition is true.
- [`progressPct()`](#progresspct) — Performs the progress pct operation on the sync module.
- [`print()`](#print) — Performs the print operation on the sync module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`onPeerHeight()`](#onpeerheight) — Notifica ca un peer are height mai mare
Returneaza GetHeaders encodat ...
- [`onBlockApplied()`](#onblockapplied) — Notifica ca un bloc nou a fost primit si validat
- [`onBlocksReceived()`](#onblocksreceived) — Proceseaza un batch de blocuri primite:
- actualizeaza local_height cu...
- [`retryIfStalled()`](#retryifstalled) — Daca sync-ul e blocat (isStalled), reseteaza la .requesting pentru ret...
- [`isStalled()`](#isstalled) — Verifica daca sync-ul a blocat (>60s fara progres)
- [`isSynced()`](#issynced) — Checks whether the synced condition is true.

---

## Structs

### `MsgGetHeaders`

Cerere: "am blocuri pana la height X, trimite-mi de la X+1"

| Field | Type | Description |
|-------|------|-------------|
| `from_height` | `u64` | From_height |
| `max_count` | `u16` | Max_count |

*Defined at line 17*

---

### `BlockHeader`

Un header compact de bloc pentru sync rapid (fara TX-uri)
88 bytes per header

| Field | Type | Description |
|-------|------|-------------|
| `height` | `u64` | Height |
| `timestamp` | `i64` | Timestamp |
| `prev_hash` | `[32]u8` | Prev_hash |
| `merkle_root` | `[32]u8` | Merkle_root |
| `nonce` | `u64` | Nonce |

*Defined at line 39*

---

### `MsgHeaders`

Raspuns la GetHeaders: lista de headere compacte

| Field | Type | Description |
|-------|------|-------------|
| `count` | `u16` | Count |
| `headers` | `[]BlockHeader` | Headers |

*Defined at line 91*

---

### `MsgBlocks`

Raspuns cu blocuri complete: [count:2][header0:88][header1:88]...
Acelasi format ca MsgHeaders dar semnifica blocuri descarcate complet

| Field | Type | Description |
|-------|------|-------------|
| `count` | `u16` | Count |
| `headers` | `[]BlockHeader` | Headers |

*Defined at line 125*

---

### `MsgGetBlocks`

Cerere blocuri complete dupa height

| Field | Type | Description |
|-------|------|-------------|
| `from_height` | `u64` | From_height |
| `max_count` | `u16` | Max_count |

*Defined at line 158*

---

### `SyncState`

Data structure for sync state. Fields include: status, local_height, peer_height, blocks_pending, started_at.

| Field | Type | Description |
|-------|------|-------------|
| `status` | `SyncStatus` | Status |
| `local_height` | `u64` | Local_height |
| `peer_height` | `u64` | Peer_height |
| `blocks_pending` | `u64` | Blocks_pending |
| `started_at` | `i64` | Started_at |
| `last_progress` | `i64` | Last_progress |

*Defined at line 187*

---

### `SyncManager`

Data structure for sync manager. Fields include: state, allocator.

| Field | Type | Description |
|-------|------|-------------|
| `state` | `SyncState` | State |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 231*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `Blockchain` | `blockchain_mod.Blockchain` | Blockchain |
| `Block` | `block_mod.Block` | Block |
| `SyncStatus` | `enum {` | Sync status |
| `MAX_HEADERS_PER_REQ` | `u16 = 2000` | M a x_ h e a d e r s_ p e r_ r e q |
| `MAX_BLOCKS_PER_REQ` | `u16 = 128` | M a x_ b l o c k s_ p e r_ r e q |

---

## Functions

### `encode()`

Decodes the encoded data back to its original format.

```zig
pub fn encode(self: MsgGetHeaders) [10]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `MsgGetHeaders` | The instance |

**Returns:** `[10]u8`

*Defined at line 21*

---

### `decode()`

Attempts to find decode. Returns null if not found.

```zig
pub fn decode(buf: []const u8) ?MsgGetHeaders {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `buf` | `[]const u8` | Buf |

**Returns:** `?MsgGetHeaders`

*Defined at line 28*

---

### `fromBlock()`

Performs the from block operation on the sync module.

```zig
pub fn fromBlock(b: *const Block, height: u64) BlockHeader {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `b` | `*const Block` | B |
| `height` | `u64` | Height |

**Returns:** `BlockHeader`

*Defined at line 46*

---

### `encode()`

Decodes the encoded data back to its original format.

```zig
pub fn encode(self: BlockHeader, buf: *[88]u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `BlockHeader` | The instance |
| `buf` | `*[88]u8` | Buf |

*Defined at line 66*

---

### `decode()`

Attempts to find decode. Returns null if not found.

```zig
pub fn decode(buf: []const u8) ?BlockHeader {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `buf` | `[]const u8` | Buf |

**Returns:** `?BlockHeader`

*Defined at line 74*

---

### `encode()`

Encode: [count:2][header0:88][header1:88]...

```zig
pub fn encode(self: MsgHeaders, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `MsgHeaders` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 96*

---

### `decode()`

Performs the decode operation on the sync module.

```zig
pub fn decode(buf: []const u8, allocator: std.mem.Allocator) !MsgHeaders {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `buf` | `[]const u8` | Buf |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!MsgHeaders`

*Defined at line 108*

---

### `encode()`

Encode: [count:2][header0:88][header1:88]...

```zig
pub fn encode(self: MsgBlocks, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `MsgBlocks` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 130*

---

### `decode()`

Performs the decode operation on the sync module.

```zig
pub fn decode(buf: []const u8, allocator: std.mem.Allocator) !MsgBlocks {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `buf` | `[]const u8` | Buf |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!MsgBlocks`

*Defined at line 142*

---

### `encode()`

Decodes the encoded data back to its original format.

```zig
pub fn encode(self: MsgGetBlocks) [10]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `MsgGetBlocks` | The instance |

**Returns:** `[10]u8`

*Defined at line 162*

---

### `decode()`

Attempts to find decode. Returns null if not found.

```zig
pub fn decode(buf: []const u8) ?MsgGetBlocks {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `buf` | `[]const u8` | Buf |

**Returns:** `?MsgGetBlocks`

*Defined at line 169*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(local_height: u64) SyncState {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `local_height` | `u64` | Local_height |

**Returns:** `SyncState`

*Defined at line 195*

---

### `isBehind()`

Checks whether the behind condition is true.

```zig
pub fn isBehind(self: *const SyncState) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SyncState` | The instance |

**Returns:** `bool`

*Defined at line 206*

---

### `progressPct()`

Performs the progress pct operation on the sync module.

```zig
pub fn progressPct(self: *const SyncState) f64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SyncState` | The instance |

**Returns:** `f64`

*Defined at line 210*

---

### `print()`

Performs the print operation on the sync module.

```zig
pub fn print(self: *const SyncState) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SyncState` | The instance |

*Defined at line 216*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(local_height: u64, allocator: std.mem.Allocator) SyncManager {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `local_height` | `u64` | Local_height |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `SyncManager`

*Defined at line 240*

---

### `onPeerHeight()`

Notifica ca un peer are height mai mare
Returneaza GetHeaders encodat daca trebuie sa sincronizam

```zig
pub fn onPeerHeight(self: *SyncManager, peer_height: u64) ?[10]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SyncManager` | The instance |
| `peer_height` | `u64` | Peer_height |

**Returns:** `?[10]u8`

*Defined at line 249*

---

### `onBlockApplied()`

Notifica ca un bloc nou a fost primit si validat

```zig
pub fn onBlockApplied(self: *SyncManager, new_height: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SyncManager` | The instance |
| `new_height` | `u64` | New_height |

*Defined at line 330*

---

### `onBlocksReceived()`

Proceseaza un batch de blocuri primite:
- actualizeaza local_height cu count blocuri noi
- actualizeaza last_progress
- trece in .synced daca am ajuns la peer_height

```zig
pub fn onBlocksReceived(self: *SyncManager, count: u32) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SyncManager` | The instance |
| `count` | `u32` | Count |

*Defined at line 347*

---

### `retryIfStalled()`

Daca sync-ul e blocat (isStalled), reseteaza la .requesting pentru retry.
Returneaza true daca s-a facut retry.

```zig
pub fn retryIfStalled(self: *SyncManager) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SyncManager` | The instance |

**Returns:** `bool`

*Defined at line 368*

---

### `isStalled()`

Verifica daca sync-ul a blocat (>60s fara progres)

```zig
pub fn isStalled(self: *const SyncManager) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SyncManager` | The instance |

**Returns:** `bool`

*Defined at line 378*

---

### `isSynced()`

Checks whether the synced condition is true.

```zig
pub fn isSynced(self: *const SyncManager) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SyncManager` | The instance |

**Returns:** `bool`

*Defined at line 384*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
