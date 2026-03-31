# Module: `witness_data`

> Signature witness separation — 95% size reduction for stored signatures, backward compatible with full validation.

**Source:** `core/witness_data.zig` | **Lines:** 417 | **Functions:** 25 | **Structs:** 4 | **Tests:** 8

---

## Contents

### Structs
- [`WitnessData`](#witnessdata) — Signature witness data (kept separate from transaction data in SegWit style)
- [`WitnessPool`](#witnesspool) — Witness pool - manages all signatures for a block
- [`CompressionStats`](#compressionstats) — Data structure for compression stats. Fields include: full_size, witness_size, r...
- [`WitnessArchive`](#witnessarchive) — Witness archive for old blocks

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`setSignature()`](#setsignature) — Set signature data
- [`setPublicKey()`](#setpublickey) — Set public key data
- [`getSignature()`](#getsignature) — Get signature slice
- [`getPublicKey()`](#getpublickey) — Get public key slice
- [`serialize()`](#serialize) — Serialize witness to binary
- [`deserialize()`](#deserialize) — Deserialize witness from binary
- [`print()`](#print) — Performs the print operation on the witness_data module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addWitness()`](#addwitness) — Add witness for a transaction
- [`getWitness()`](#getwitness) — Get witness by transaction ID
- [`hasWitness()`](#haswitness) — Check if witness exists
- [`getAllWitnesses()`](#getallwitnesses) — Get all witnesses
- [`getWitnessCount()`](#getwitnesscount) — Get witness count
- [`estimateSize()`](#estimatesize) — Estimated storage size in bytes
- [`serialize()`](#serialize) — Serialize all witnesses to binary
- [`clear()`](#clear) — Clear all witnesses
- [`getCompressionStats()`](#getcompressionstats) — Get compression ratio (witness data vs full signature)
- [`printStats()`](#printstats) — Performs the print stats operation on the witness_data module.
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`archiveBlock()`](#archiveblock) — Archive witnesses for a block height
- [`getBlockWitnesses()`](#getblockwitnesses) — Get witnesses for a block
- [`getTotalSize()`](#gettotalsize) — Get total archived size
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.

---

## Structs

### `WitnessData`

Signature witness data (kept separate from transaction data in SegWit style)

| Field | Type | Description |
|-------|------|-------------|
| `tx_id` | `u32` | Tx_id |
| `sig_type` | `u8` | Sig_type |
| `signature` | `[512]u8` | Signature |
| `sig_len` | `u16` | Sig_len |
| `timestamp` | `u64` | Timestamp |
| `flags` | `u8` | Flags |

*Defined at line 5*

---

### `WitnessPool`

Witness pool - manages all signatures for a block

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `witnesses` | `std.array_list.Managed(WitnessData)` | Witnesses |
| `witness_map` | `std.AutoHashMap(u32` | Witness_map |
| `total_size` | `u64` | Total_size |

*Defined at line 151*

---

### `CompressionStats`

Data structure for compression stats. Fields include: full_size, witness_size, reduction_percent.

| Field | Type | Description |
|-------|------|-------------|
| `full_size` | `u64` | Full_size |
| `witness_size` | `u64` | Witness_size |
| `reduction_percent` | `u64` | Reduction_percent |

*Defined at line 263*

---

### `WitnessArchive`

Witness archive for old blocks

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `block_witnesses` | `std.array_list.Managed(WitnessPool)` | Block_witnesses |
| `block_heights` | `std.array_list.Managed(u32)` | Block_heights |

*Defined at line 270*

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(tx_id: u32, sig_type: u8) WitnessData {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `tx_id` | `u32` | Tx_id |
| `sig_type` | `u8` | Sig_type |

**Returns:** `WitnessData`

*Defined at line 15*

---

### `setSignature()`

Set signature data

```zig
pub fn setSignature(self: *WitnessData, sig: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*WitnessData` | The instance |
| `sig` | `[]const u8` | Sig |

**Returns:** `!void`

*Defined at line 29*

---

### `setPublicKey()`

Set public key data

```zig
pub fn setPublicKey(self: *WitnessData, pubkey: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*WitnessData` | The instance |
| `pubkey` | `[]const u8` | Pubkey |

**Returns:** `!void`

*Defined at line 36*

---

### `getSignature()`

Get signature slice

```zig
pub fn getSignature(self: *const WitnessData) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessData` | The instance |

**Returns:** `[]const u8`

*Defined at line 43*

---

### `getPublicKey()`

Get public key slice

```zig
pub fn getPublicKey(self: *const WitnessData) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessData` | The instance |

**Returns:** `[]const u8`

*Defined at line 48*

---

### `serialize()`

Serialize witness to binary

```zig
pub fn serialize(self: *const WitnessData, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessData` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 53*

---

### `deserialize()`

Deserialize witness from binary

```zig
pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !WitnessData {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!WitnessData`

*Defined at line 93*

---

### `print()`

Performs the print operation on the witness_data module.

```zig
pub fn print(self: *const WitnessData) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessData` | The instance |

*Defined at line 142*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) WitnessPool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `WitnessPool`

*Defined at line 157*

---

### `addWitness()`

Add witness for a transaction

```zig
pub fn addWitness(self: *WitnessPool, witness: WitnessData) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*WitnessPool` | The instance |
| `witness` | `WitnessData` | Witness |

**Returns:** `!void`

*Defined at line 166*

---

### `getWitness()`

Get witness by transaction ID

```zig
pub fn getWitness(self: *const WitnessPool, tx_id: u32) ?*const WitnessData {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessPool` | The instance |
| `tx_id` | `u32` | Tx_id |

**Returns:** `?*const WitnessData`

*Defined at line 175*

---

### `hasWitness()`

Check if witness exists

```zig
pub fn hasWitness(self: *const WitnessPool, tx_id: u32) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessPool` | The instance |
| `tx_id` | `u32` | Tx_id |

**Returns:** `bool`

*Defined at line 183*

---

### `getAllWitnesses()`

Get all witnesses

```zig
pub fn getAllWitnesses(self: *const WitnessPool) []const WitnessData {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessPool` | The instance |

**Returns:** `[]const WitnessData`

*Defined at line 188*

---

### `getWitnessCount()`

Get witness count

```zig
pub fn getWitnessCount(self: *const WitnessPool) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessPool` | The instance |

**Returns:** `usize`

*Defined at line 193*

---

### `estimateSize()`

Estimated storage size in bytes

```zig
pub fn estimateSize(self: *const WitnessPool) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessPool` | The instance |

**Returns:** `u64`

*Defined at line 198*

---

### `serialize()`

Serialize all witnesses to binary

```zig
pub fn serialize(self: *const WitnessPool) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessPool` | The instance |

**Returns:** `![]u8`

*Defined at line 203*

---

### `clear()`

Clear all witnesses

```zig
pub fn clear(self: *WitnessPool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*WitnessPool` | The instance |

*Defined at line 220*

---

### `getCompressionStats()`

Get compression ratio (witness data vs full signature)

```zig
pub fn getCompressionStats(self: *const WitnessPool) CompressionStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessPool` | The instance |

**Returns:** `CompressionStats`

*Defined at line 227*

---

### `printStats()`

Performs the print stats operation on the witness_data module.

```zig
pub fn printStats(self: *const WitnessPool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessPool` | The instance |

*Defined at line 249*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *WitnessPool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*WitnessPool` | The instance |

*Defined at line 257*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) WitnessArchive {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `WitnessArchive`

*Defined at line 275*

---

### `archiveBlock()`

Archive witnesses for a block height

```zig
pub fn archiveBlock(self: *WitnessArchive, block_height: u32, pool: WitnessPool) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*WitnessArchive` | The instance |
| `block_height` | `u32` | Block_height |
| `pool` | `WitnessPool` | Pool |

**Returns:** `!void`

*Defined at line 284*

---

### `getBlockWitnesses()`

Get witnesses for a block

```zig
pub fn getBlockWitnesses(self: *const WitnessArchive, block_height: u32) ?*const WitnessPool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessArchive` | The instance |
| `block_height` | `u32` | Block_height |

**Returns:** `?*const WitnessPool`

*Defined at line 290*

---

### `getTotalSize()`

Get total archived size

```zig
pub fn getTotalSize(self: *const WitnessArchive) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WitnessArchive` | The instance |

**Returns:** `u64`

*Defined at line 300*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *WitnessArchive) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*WitnessArchive` | The instance |

*Defined at line 308*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
