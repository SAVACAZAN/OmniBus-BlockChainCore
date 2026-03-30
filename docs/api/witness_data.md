# Module: `witness_data`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `WitnessData`

Signature witness data (kept separate from transaction data in SegWit style)

*Line: 5*

### `WitnessPool`

Witness pool - manages all signatures for a block

*Line: 151*

### `CompressionStats`

*Line: 263*

### `WitnessArchive`

Witness archive for old blocks

*Line: 270*

## Functions

### `init`

```zig
pub fn init(tx_id: u32, sig_type: u8) WitnessData {
```

**Parameters:**

- `tx_id`: `u32`
- `sig_type`: `u8`

**Returns:** `WitnessData`

*Line: 15*

---

### `setSignature`

Set signature data

```zig
pub fn setSignature(self: *WitnessData, sig: []const u8) !void {
```

**Parameters:**

- `self`: `*WitnessData`
- `sig`: `[]const u8`

**Returns:** `!void`

*Line: 29*

---

### `setPublicKey`

Set public key data

```zig
pub fn setPublicKey(self: *WitnessData, pubkey: []const u8) !void {
```

**Parameters:**

- `self`: `*WitnessData`
- `pubkey`: `[]const u8`

**Returns:** `!void`

*Line: 36*

---

### `getSignature`

Get signature slice

```zig
pub fn getSignature(self: *const WitnessData) []const u8 {
```

**Parameters:**

- `self`: `*const WitnessData`

**Returns:** `[]const u8`

*Line: 43*

---

### `getPublicKey`

Get public key slice

```zig
pub fn getPublicKey(self: *const WitnessData) []const u8 {
```

**Parameters:**

- `self`: `*const WitnessData`

**Returns:** `[]const u8`

*Line: 48*

---

### `serialize`

Serialize witness to binary

```zig
pub fn serialize(self: *const WitnessData, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const WitnessData`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 53*

---

### `deserialize`

Deserialize witness from binary

```zig
pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !WitnessData {
```

**Parameters:**

- `data`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!WitnessData`

*Line: 93*

---

### `print`

```zig
pub fn print(self: *const WitnessData) void {
```

**Parameters:**

- `self`: `*const WitnessData`

*Line: 142*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) WitnessPool {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `WitnessPool`

*Line: 157*

---

### `addWitness`

Add witness for a transaction

```zig
pub fn addWitness(self: *WitnessPool, witness: WitnessData) !void {
```

**Parameters:**

- `self`: `*WitnessPool`
- `witness`: `WitnessData`

**Returns:** `!void`

*Line: 166*

---

### `getWitness`

Get witness by transaction ID

```zig
pub fn getWitness(self: *const WitnessPool, tx_id: u32) ?*const WitnessData {
```

**Parameters:**

- `self`: `*const WitnessPool`
- `tx_id`: `u32`

**Returns:** `?*const WitnessData`

*Line: 175*

---

### `hasWitness`

Check if witness exists

```zig
pub fn hasWitness(self: *const WitnessPool, tx_id: u32) bool {
```

**Parameters:**

- `self`: `*const WitnessPool`
- `tx_id`: `u32`

**Returns:** `bool`

*Line: 183*

---

### `getAllWitnesses`

Get all witnesses

```zig
pub fn getAllWitnesses(self: *const WitnessPool) []const WitnessData {
```

**Parameters:**

- `self`: `*const WitnessPool`

**Returns:** `[]const WitnessData`

*Line: 188*

---

### `getWitnessCount`

Get witness count

```zig
pub fn getWitnessCount(self: *const WitnessPool) usize {
```

**Parameters:**

- `self`: `*const WitnessPool`

**Returns:** `usize`

*Line: 193*

---

### `estimateSize`

Estimated storage size in bytes

```zig
pub fn estimateSize(self: *const WitnessPool) u64 {
```

**Parameters:**

- `self`: `*const WitnessPool`

**Returns:** `u64`

*Line: 198*

---

### `serialize`

Serialize all witnesses to binary

```zig
pub fn serialize(self: *const WitnessPool) ![]u8 {
```

**Parameters:**

- `self`: `*const WitnessPool`

**Returns:** `![]u8`

*Line: 203*

---

### `clear`

Clear all witnesses

```zig
pub fn clear(self: *WitnessPool) void {
```

**Parameters:**

- `self`: `*WitnessPool`

*Line: 220*

---

### `getCompressionStats`

Get compression ratio (witness data vs full signature)

```zig
pub fn getCompressionStats(self: *const WitnessPool) CompressionStats {
```

**Parameters:**

- `self`: `*const WitnessPool`

**Returns:** `CompressionStats`

*Line: 227*

---

### `printStats`

```zig
pub fn printStats(self: *const WitnessPool) void {
```

**Parameters:**

- `self`: `*const WitnessPool`

*Line: 249*

---

### `deinit`

```zig
pub fn deinit(self: *WitnessPool) void {
```

**Parameters:**

- `self`: `*WitnessPool`

*Line: 257*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) WitnessArchive {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `WitnessArchive`

*Line: 275*

---

### `archiveBlock`

Archive witnesses for a block height

```zig
pub fn archiveBlock(self: *WitnessArchive, block_height: u32, pool: WitnessPool) !void {
```

**Parameters:**

- `self`: `*WitnessArchive`
- `block_height`: `u32`
- `pool`: `WitnessPool`

**Returns:** `!void`

*Line: 284*

---

### `getBlockWitnesses`

Get witnesses for a block

```zig
pub fn getBlockWitnesses(self: *const WitnessArchive, block_height: u32) ?*const WitnessPool {
```

**Parameters:**

- `self`: `*const WitnessArchive`
- `block_height`: `u32`

**Returns:** `?*const WitnessPool`

*Line: 290*

---

### `getTotalSize`

Get total archived size

```zig
pub fn getTotalSize(self: *const WitnessArchive) u64 {
```

**Parameters:**

- `self`: `*const WitnessArchive`

**Returns:** `u64`

*Line: 300*

---

### `deinit`

```zig
pub fn deinit(self: *WitnessArchive) void {
```

**Parameters:**

- `self`: `*WitnessArchive`

*Line: 308*

---

