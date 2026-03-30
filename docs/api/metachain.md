# Module: `metachain`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `ShardBlockHeader`

Header rezumat al unui shard block — trimis la Metachain pentru confirmare

*Line: 20*

### `CrossShardReceipt`

Cross-shard receipt — confirmă că o TX cross-shard a fost procesată
La EGLD: faza 1 = scade din shard sursei; faza 2 = creditează în shard destinației

*Line: 32*

### `MetaBlock`

MetaBlock — blocul Metachain-ului (1 per secundă)

*Line: 50*

### `Metachain`

Metachain — chain de MetaBlock-uri, coordonator global

*Line: 141*

## Constants

| Name | Type | Value |
|------|------|-------|
| `ShardCoordinator` | auto | `shard_coord_mod.ShardCoordinator` |
| `METACHAIN_SHARD` | auto | `shard_coord_mod.METACHAIN_SHARD` |
| `CrossShardPhase` | auto | `enum(u8) {` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, height: u64, prev_hash: [32]u8) MetaBlock {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `height`: `u64`
- `prev_hash`: `[32]u8`

**Returns:** `MetaBlock`

*Line: 68*

---

### `deinit`

```zig
pub fn deinit(self: *MetaBlock) void {
```

**Parameters:**

- `self`: `*MetaBlock`

*Line: 81*

---

### `addShardHeader`

Adaugă header-ul unui shard la acest MetaBlock

```zig
pub fn addShardHeader(self: *MetaBlock, hdr: ShardBlockHeader) !void {
```

**Parameters:**

- `self`: `*MetaBlock`
- `hdr`: `ShardBlockHeader`

**Returns:** `!void`

*Line: 87*

---

### `addCrossReceipt`

Adaugă un receipt cross-shard

```zig
pub fn addCrossReceipt(self: *MetaBlock, receipt: CrossShardReceipt) !void {
```

**Parameters:**

- `self`: `*MetaBlock`
- `receipt`: `CrossShardReceipt`

**Returns:** `!void`

*Line: 96*

---

### `calculateHash`

Calculează hash-ul MetaBlock-ului (SHA256 peste toate datele)

```zig
pub fn calculateHash(self: *MetaBlock) void {
```

**Parameters:**

- `self`: `*MetaBlock`

*Line: 101*

---

### `isComplete`

```zig
pub fn isComplete(self: *const MetaBlock, expected_shards: u8) bool {
```

**Parameters:**

- `self`: `*const MetaBlock`
- `expected_shards`: `u8`

**Returns:** `bool`

*Line: 135*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, num_shards: u8) !Metachain {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `num_shards`: `u8`

**Returns:** `!Metachain`

*Line: 149*

---

### `deinit`

```zig
pub fn deinit(self: *Metachain) void {
```

**Parameters:**

- `self`: `*Metachain`

*Line: 165*

---

### `getHeight`

```zig
pub fn getHeight(self: *const Metachain) u64 {
```

**Parameters:**

- `self`: `*const Metachain`

**Returns:** `u64`

*Line: 171*

---

### `getLatestHash`

```zig
pub fn getLatestHash(self: *const Metachain) [32]u8 {
```

**Parameters:**

- `self`: `*const Metachain`

**Returns:** `[32]u8`

*Line: 175*

---

### `beginMetaBlock`

Creează un nou MetaBlock gol pentru height-ul următor

```zig
pub fn beginMetaBlock(self: *Metachain) !*MetaBlock {
```

**Parameters:**

- `self`: `*Metachain`

**Returns:** `!*MetaBlock`

*Line: 180*

---

### `finalizeMetaBlock`

Finalizează MetaBlock-ul curent: calculează hash + procesează receipts pending

```zig
pub fn finalizeMetaBlock(self: *Metachain) !void {
```

**Parameters:**

- `self`: `*Metachain`

**Returns:** `!void`

*Line: 189*

---

### `printStatus`

```zig
pub fn printStatus(self: *const Metachain) void {
```

**Parameters:**

- `self`: `*const Metachain`

*Line: 257*

---

