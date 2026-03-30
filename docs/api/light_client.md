# Module: `light_client`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `BlockHeader`

Minimal block header for light client (only ~200 bytes vs 35KB full block)

*Line: 5*

### `LightClient`

Light Client - minimal blockchain for low-resource devices

*Line: 125*

### `SPVProof`

SPV (Simplified Payment Verification) proof for light clients

*Line: 292*

### `BloomFilter`

Bloom filter for transaction filtering (reduce data transfer)

*Line: 320*

## Functions

### `init`

```zig
pub fn init(index: u32) BlockHeader {
```

**Parameters:**

- `index`: `u32`

**Returns:** `BlockHeader`

*Line: 16*

---

### `serialize`

Serialize header to binary (lightweight)

```zig
pub fn serialize(self: *const BlockHeader) [200]u8 {
```

**Parameters:**

- `self`: `*const BlockHeader`

**Returns:** `[200]u8`

*Line: 31*

---

### `deserialize`

Deserialize header from binary

```zig
pub fn deserialize(data: [200]u8) BlockHeader {
```

**Parameters:**

- `data`: `[200]u8`

**Returns:** `BlockHeader`

*Line: 74*

---

### `print`

```zig
pub fn print(self: *const BlockHeader) void {
```

**Parameters:**

- `self`: `*const BlockHeader`

*Line: 116*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) LightClient {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `LightClient`

*Line: 132*

---

### `addHeader`

Add block header to chain

```zig
pub fn addHeader(self: *LightClient, header: BlockHeader) !void {
```

**Parameters:**

- `self`: `*LightClient`
- `header`: `BlockHeader`

**Returns:** `!void`

*Line: 141*

---

### `verifyChain`

Verify header chain (check previous_hash links)

```zig
pub fn verifyChain(self: *const LightClient) bool {
```

**Parameters:**

- `self`: `*const LightClient`

**Returns:** `bool`

*Line: 155*

---

### `getHeader`

Get header by block height

```zig
pub fn getHeader(self: *const LightClient, height: u32) ?*const BlockHeader {
```

**Parameters:**

- `self`: `*const LightClient`
- `height`: `u32`

**Returns:** `?*const BlockHeader`

*Line: 177*

---

### `getLatestHeader`

Get latest header

```zig
pub fn getLatestHeader(self: *const LightClient) ?*const BlockHeader {
```

**Parameters:**

- `self`: `*const LightClient`

**Returns:** `?*const BlockHeader`

*Line: 187*

---

### `getHeaderCount`

Get header count

```zig
pub fn getHeaderCount(self: *const LightClient) usize {
```

**Parameters:**

- `self`: `*const LightClient`

**Returns:** `usize`

*Line: 193*

---

### `estimateStorageSize`

Estimate storage used (headers only)

```zig
pub fn estimateStorageSize(self: *const LightClient) u64 {
```

**Parameters:**

- `self`: `*const LightClient`

**Returns:** `u64`

*Line: 198*

---

### `fastSyncFromCheckpoint`

Fast sync from trusted checkpoint

```zig
pub fn fastSyncFromCheckpoint(self: *LightClient, trusted_header: BlockHeader, new_headers: []const BlockHeader) !void {
```

**Parameters:**

- `self`: `*LightClient`
- `trusted_header`: `BlockHeader`
- `new_headers`: `[]const BlockHeader`

**Returns:** `!void`

*Line: 204*

---

### `getDifficulty`

Get proof-of-work difficulty at height

```zig
pub fn getDifficulty(self: *const LightClient, height: u32) u32 {
```

**Parameters:**

- `self`: `*const LightClient`
- `height`: `u32`

**Returns:** `u32`

*Line: 220*

---

### `serializeToFile`

Serialize headers to file format

```zig
pub fn serializeToFile(self: *const LightClient, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const LightClient`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 228*

---

### `deserializeFromFile`

Deserialize headers from file format

```zig
pub fn deserializeFromFile(self: *LightClient, data: []const u8) !void {
```

**Parameters:**

- `self`: `*LightClient`
- `data`: `[]const u8`

**Returns:** `!void`

*Line: 244*

---

### `printStats`

Statistics about light client

```zig
pub fn printStats(self: *const LightClient) void {
```

**Parameters:**

- `self`: `*const LightClient`

*Line: 267*

---

### `deinit`

```zig
pub fn deinit(self: *LightClient) void {
```

**Parameters:**

- `self`: `*LightClient`

*Line: 286*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, tx_hash: [32]u8, header: BlockHeader) SPVProof {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `tx_hash`: `[32]u8`
- `header`: `BlockHeader`

**Returns:** `SPVProof`

*Line: 298*

---

### `verifyProof`

Verify SPV proof against block header

```zig
pub fn verifyProof(self: *const SPVProof) bool {
```

**Parameters:**

- `self`: `*const SPVProof`

**Returns:** `bool`

*Line: 308*

---

### `deinit`

```zig
pub fn deinit(self: *SPVProof) void {
```

**Parameters:**

- `self`: `*SPVProof`

*Line: 314*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) BloomFilter {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `BloomFilter`

*Line: 325*

---

### `add`

Insert address into filter

```zig
pub fn add(self: *BloomFilter, address: []const u8) !void {
```

**Parameters:**

- `self`: `*BloomFilter`
- `address`: `[]const u8`

**Returns:** `!void`

*Line: 333*

---

### `contains`

Check if address might be in filter (has false positives)

```zig
pub fn contains(self: *const BloomFilter, address: []const u8) bool {
```

**Parameters:**

- `self`: `*const BloomFilter`
- `address`: `[]const u8`

**Returns:** `bool`

*Line: 353*

---

### `deinit`

```zig
pub fn deinit(self: *BloomFilter) void {
```

**Parameters:**

- `self`: `*BloomFilter`

*Line: 368*

---

