# Module: `storage`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `TxLocation`

Locatia unei tranzactii in blockchain

*Line: 4*

### `KeyValueStore`

Key-Value Storage Interface
Abstracts RocksDB, SQLite, or file-based storage

*Line: 8*

### `BlockStore`

Block Storage

*Line: 77*

### `TransactionIndex`

Transaction Index

*Line: 124*

### `AddressIndex`

Address Balance Index

*Line: 177*

### `StateCheckpoint`

State Checkpoint for Recovery

*Line: 220*

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) KeyValueStore {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `KeyValueStore`

*Line: 12*

---

### `deinit`

```zig
pub fn deinit(self: *KeyValueStore) void {
```

**Parameters:**

- `self`: `*KeyValueStore`

*Line: 19*

---

### `put`

Put key-value pair

```zig
pub fn put(self: *KeyValueStore, key: []const u8, value: []const u8) !void {
```

**Parameters:**

- `self`: `*KeyValueStore`
- `key`: `[]const u8`
- `value`: `[]const u8`

**Returns:** `!void`

*Line: 29*

---

### `get`

Get value by key

```zig
pub fn get(self: *const KeyValueStore, key: []const u8) ?[]u8 {
```

**Parameters:**

- `self`: `*const KeyValueStore`
- `key`: `[]const u8`

**Returns:** `?[]u8`

*Line: 41*

---

### `delete`

Delete key-value pair

```zig
pub fn delete(self: *KeyValueStore, key: []const u8) !void {
```

**Parameters:**

- `self`: `*KeyValueStore`
- `key`: `[]const u8`

**Returns:** `!void`

*Line: 46*

---

### `contains`

Check if key exists

```zig
pub fn contains(self: *const KeyValueStore, key: []const u8) bool {
```

**Parameters:**

- `self`: `*const KeyValueStore`
- `key`: `[]const u8`

**Returns:** `bool`

*Line: 54*

---

### `count`

Get total entries

```zig
pub fn count(self: *const KeyValueStore) usize {
```

**Parameters:**

- `self`: `*const KeyValueStore`

**Returns:** `usize`

*Line: 59*

---

### `clear`

Clear all entries

```zig
pub fn clear(self: *KeyValueStore) void {
```

**Parameters:**

- `self`: `*KeyValueStore`

*Line: 64*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) BlockStore {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `BlockStore`

*Line: 81*

---

### `deinit`

```zig
pub fn deinit(self: *BlockStore) void {
```

**Parameters:**

- `self`: `*BlockStore`

*Line: 88*

---

### `storeBlock`

Store block with key "block:[height]"

```zig
pub fn storeBlock(self: *BlockStore, block_height: u64, block_data: []const u8) !void {
```

**Parameters:**

- `self`: `*BlockStore`
- `block_height`: `u64`
- `block_data`: `[]const u8`

**Returns:** `!void`

*Line: 93*

---

### `getBlock`

Retrieve block by height

```zig
pub fn getBlock(self: *const BlockStore, block_height: u64) ?[]u8 {
```

**Parameters:**

- `self`: `*const BlockStore`
- `block_height`: `u64`

**Returns:** `?[]u8`

*Line: 104*

---

### `blockCount`

Get total blocks stored

```zig
pub fn blockCount(self: *const BlockStore) u64 {
```

**Parameters:**

- `self`: `*const BlockStore`

**Returns:** `u64`

*Line: 111*

---

### `deleteBlock`

Delete block

```zig
pub fn deleteBlock(self: *BlockStore, block_height: u64) !void {
```

**Parameters:**

- `self`: `*BlockStore`
- `block_height`: `u64`

**Returns:** `!void`

*Line: 116*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) TransactionIndex {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `TransactionIndex`

*Line: 128*

---

### `deinit`

```zig
pub fn deinit(self: *TransactionIndex) void {
```

**Parameters:**

- `self`: `*TransactionIndex`

*Line: 135*

---

### `indexTransaction`

Index transaction: "tx:[hash]" → "block_height:tx_index"

```zig
pub fn indexTransaction(self: *TransactionIndex, tx_hash: []const u8, block_height: u64, tx_index: u32) !void {
```

**Parameters:**

- `self`: `*TransactionIndex`
- `tx_hash`: `[]const u8`
- `block_height`: `u64`
- `tx_index`: `u32`

**Returns:** `!void`

*Line: 140*

---

### `findTransaction`

Find transaction location

```zig
pub fn findTransaction(self: *const TransactionIndex, tx_hash: []const u8) ?TxLocation {
```

**Parameters:**

- `self`: `*const TransactionIndex`
- `tx_hash`: `[]const u8`

**Returns:** `?TxLocation`

*Line: 152*

---

### `transactionCount`

Get total indexed transactions

```zig
pub fn transactionCount(self: *const TransactionIndex) u64 {
```

**Parameters:**

- `self`: `*const TransactionIndex`

**Returns:** `u64`

*Line: 171*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) AddressIndex {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `AddressIndex`

*Line: 180*

---

### `deinit`

```zig
pub fn deinit(self: *AddressIndex) void {
```

**Parameters:**

- `self`: `*AddressIndex`

*Line: 186*

---

### `updateBalance`

Update address balance: "addr:[address]" → "balance"

```zig
pub fn updateBalance(self: *AddressIndex, address: []const u8, balance: u64) !void {
```

**Parameters:**

- `self`: `*AddressIndex`
- `address`: `[]const u8`
- `balance`: `u64`

**Returns:** `!void`

*Line: 191*

---

### `getBalance`

Get address balance

```zig
pub fn getBalance(self: *const AddressIndex, address: []const u8) ?u64 {
```

**Parameters:**

- `self`: `*const AddressIndex`
- `address`: `[]const u8`

**Returns:** `?u64`

*Line: 202*

---

### `addressCount`

Get all addresses

```zig
pub fn addressCount(self: *const AddressIndex) usize {
```

**Parameters:**

- `self`: `*const AddressIndex`

**Returns:** `usize`

*Line: 214*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) StateCheckpoint {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `StateCheckpoint`

*Line: 224*

---

### `deinit`

```zig
pub fn deinit(self: *StateCheckpoint) void {
```

**Parameters:**

- `self`: `*StateCheckpoint`

*Line: 231*

---

### `save`

Save checkpoint: "checkpoint:[number]" → state_data

```zig
pub fn save(self: *StateCheckpoint, state_data: []const u8) !u32 {
```

**Parameters:**

- `self`: `*StateCheckpoint`
- `state_data`: `[]const u8`

**Returns:** `!u32`

*Line: 236*

---

### `load`

Load checkpoint

```zig
pub fn load(self: *const StateCheckpoint, checkpoint_number: u32) ?[]u8 {
```

**Parameters:**

- `self`: `*const StateCheckpoint`
- `checkpoint_number`: `u32`

**Returns:** `?[]u8`

*Line: 257*

---

### `latest`

Get latest checkpoint

```zig
pub fn latest(self: *const StateCheckpoint) ?[]u8 {
```

**Parameters:**

- `self`: `*const StateCheckpoint`

**Returns:** `?[]u8`

*Line: 264*

---

