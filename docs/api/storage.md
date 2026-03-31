# Module: `storage`

> Key-value storage engine — in-memory with optional disk persistence, iterator support, memory-safe deinit.

**Source:** `core/storage.zig` | **Lines:** 331 | **Functions:** 29 | **Structs:** 6 | **Tests:** 6

---

## Contents

### Structs
- [`TxLocation`](#txlocation) — Locatia unei tranzactii in blockchain
- [`KeyValueStore`](#keyvaluestore) — Key-Value Storage Interface
Abstracts RocksDB, SQLite, or file-based storage
- [`BlockStore`](#blockstore) — Block Storage
- [`TransactionIndex`](#transactionindex) — Transaction Index
- [`AddressIndex`](#addressindex) — Address Balance Index
- [`StateCheckpoint`](#statecheckpoint) — State Checkpoint for Recovery

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`put()`](#put) — Put key-value pair
- [`get()`](#get) — Get value by key
- [`delete()`](#delete) — Delete key-value pair
- [`contains()`](#contains) — Check if key exists
- [`count()`](#count) — Get total entries
- [`clear()`](#clear) — Clear all entries
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`storeBlock()`](#storeblock) — Store block with key "block:[height]"
- [`getBlock()`](#getblock) — Retrieve block by height
- [`blockCount()`](#blockcount) — Get total blocks stored
- [`deleteBlock()`](#deleteblock) — Delete block
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`indexTransaction()`](#indextransaction) — Index transaction: "tx:[hash]" → "block_height:tx_index"
- [`findTransaction()`](#findtransaction) — Find transaction location
- [`transactionCount()`](#transactioncount) — Get total indexed transactions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`updateBalance()`](#updatebalance) — Update address balance: "addr:[address]" → "balance"
- [`getBalance()`](#getbalance) — Get address balance
- [`addressCount()`](#addresscount) — Get all addresses
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`save()`](#save) — Save checkpoint: "checkpoint:[number]" → state_data
- [`load()`](#load) — Load checkpoint
- [`latest()`](#latest) — Get latest checkpoint

---

## Structs

### `TxLocation`

Locatia unei tranzactii in blockchain

*Defined at line 4*

---

### `KeyValueStore`

Key-Value Storage Interface
Abstracts RocksDB, SQLite, or file-based storage

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `data` | `std.StringHashMap([]u8)` | Data |

*Defined at line 8*

---

### `BlockStore`

Block Storage

| Field | Type | Description |
|-------|------|-------------|
| `store` | `KeyValueStore` | Store |
| `next_block_id` | `u64` | Next_block_id |

*Defined at line 77*

---

### `TransactionIndex`

Transaction Index

| Field | Type | Description |
|-------|------|-------------|
| `store` | `KeyValueStore` | Store |
| `tx_count` | `u64` | Tx_count |

*Defined at line 124*

---

### `AddressIndex`

Address Balance Index

| Field | Type | Description |
|-------|------|-------------|
| `store` | `KeyValueStore` | Store |

*Defined at line 177*

---

### `StateCheckpoint`

State Checkpoint for Recovery

| Field | Type | Description |
|-------|------|-------------|
| `store` | `KeyValueStore` | Store |
| `checkpoint_count` | `u32` | Checkpoint_count |

*Defined at line 220*

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) KeyValueStore {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `KeyValueStore`

*Defined at line 12*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *KeyValueStore) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*KeyValueStore` | The instance |

*Defined at line 19*

---

### `put()`

Put key-value pair

```zig
pub fn put(self: *KeyValueStore, key: []const u8, value: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*KeyValueStore` | The instance |
| `key` | `[]const u8` | Key |
| `value` | `[]const u8` | Value |

**Returns:** `!void`

*Defined at line 29*

---

### `get()`

Get value by key

```zig
pub fn get(self: *const KeyValueStore, key: []const u8) ?[]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const KeyValueStore` | The instance |
| `key` | `[]const u8` | Key |

**Returns:** `?[]u8`

*Defined at line 41*

---

### `delete()`

Delete key-value pair

```zig
pub fn delete(self: *KeyValueStore, key: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*KeyValueStore` | The instance |
| `key` | `[]const u8` | Key |

**Returns:** `!void`

*Defined at line 46*

---

### `contains()`

Check if key exists

```zig
pub fn contains(self: *const KeyValueStore, key: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const KeyValueStore` | The instance |
| `key` | `[]const u8` | Key |

**Returns:** `bool`

*Defined at line 54*

---

### `count()`

Get total entries

```zig
pub fn count(self: *const KeyValueStore) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const KeyValueStore` | The instance |

**Returns:** `usize`

*Defined at line 59*

---

### `clear()`

Clear all entries

```zig
pub fn clear(self: *KeyValueStore) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*KeyValueStore` | The instance |

*Defined at line 64*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) BlockStore {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `BlockStore`

*Defined at line 81*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *BlockStore) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockStore` | The instance |

*Defined at line 88*

---

### `storeBlock()`

Store block with key "block:[height]"

```zig
pub fn storeBlock(self: *BlockStore, block_height: u64, block_data: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockStore` | The instance |
| `block_height` | `u64` | Block_height |
| `block_data` | `[]const u8` | Block_data |

**Returns:** `!void`

*Defined at line 93*

---

### `getBlock()`

Retrieve block by height

```zig
pub fn getBlock(self: *const BlockStore, block_height: u64) ?[]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockStore` | The instance |
| `block_height` | `u64` | Block_height |

**Returns:** `?[]u8`

*Defined at line 104*

---

### `blockCount()`

Get total blocks stored

```zig
pub fn blockCount(self: *const BlockStore) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockStore` | The instance |

**Returns:** `u64`

*Defined at line 111*

---

### `deleteBlock()`

Delete block

```zig
pub fn deleteBlock(self: *BlockStore, block_height: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlockStore` | The instance |
| `block_height` | `u64` | Block_height |

**Returns:** `!void`

*Defined at line 116*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) TransactionIndex {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `TransactionIndex`

*Defined at line 128*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *TransactionIndex) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*TransactionIndex` | The instance |

*Defined at line 135*

---

### `indexTransaction()`

Index transaction: "tx:[hash]" → "block_height:tx_index"

```zig
pub fn indexTransaction(self: *TransactionIndex, tx_hash: []const u8, block_height: u64, tx_index: u32) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*TransactionIndex` | The instance |
| `tx_hash` | `[]const u8` | Tx_hash |
| `block_height` | `u64` | Block_height |
| `tx_index` | `u32` | Tx_index |

**Returns:** `!void`

*Defined at line 140*

---

### `findTransaction()`

Find transaction location

```zig
pub fn findTransaction(self: *const TransactionIndex, tx_hash: []const u8) ?TxLocation {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const TransactionIndex` | The instance |
| `tx_hash` | `[]const u8` | Tx_hash |

**Returns:** `?TxLocation`

*Defined at line 152*

---

### `transactionCount()`

Get total indexed transactions

```zig
pub fn transactionCount(self: *const TransactionIndex) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const TransactionIndex` | The instance |

**Returns:** `u64`

*Defined at line 171*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) AddressIndex {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `AddressIndex`

*Defined at line 180*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *AddressIndex) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*AddressIndex` | The instance |

*Defined at line 186*

---

### `updateBalance()`

Update address balance: "addr:[address]" → "balance"

```zig
pub fn updateBalance(self: *AddressIndex, address: []const u8, balance: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*AddressIndex` | The instance |
| `address` | `[]const u8` | Address |
| `balance` | `u64` | Balance |

**Returns:** `!void`

*Defined at line 191*

---

### `getBalance()`

Get address balance

```zig
pub fn getBalance(self: *const AddressIndex, address: []const u8) ?u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const AddressIndex` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `?u64`

*Defined at line 202*

---

### `addressCount()`

Get all addresses

```zig
pub fn addressCount(self: *const AddressIndex) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const AddressIndex` | The instance |

**Returns:** `usize`

*Defined at line 214*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) StateCheckpoint {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `StateCheckpoint`

*Defined at line 224*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *StateCheckpoint) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StateCheckpoint` | The instance |

*Defined at line 231*

---

### `save()`

Save checkpoint: "checkpoint:[number]" → state_data

```zig
pub fn save(self: *StateCheckpoint, state_data: []const u8) !u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StateCheckpoint` | The instance |
| `state_data` | `[]const u8` | State_data |

**Returns:** `!u32`

*Defined at line 236*

---

### `load()`

Load checkpoint

```zig
pub fn load(self: *const StateCheckpoint, checkpoint_number: u32) ?[]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateCheckpoint` | The instance |
| `checkpoint_number` | `u32` | Checkpoint_number |

**Returns:** `?[]u8`

*Defined at line 257*

---

### `latest()`

Get latest checkpoint

```zig
pub fn latest(self: *const StateCheckpoint) ?[]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateCheckpoint` | The instance |

**Returns:** `?[]u8`

*Defined at line 264*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
