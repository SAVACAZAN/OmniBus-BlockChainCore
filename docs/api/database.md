# Module: `database`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `Database`

Database: Unified storage layer
Combines block, transaction, address, and checkpoint storage

*Line: 15*

### `DatabaseStats`

*Line: 114*

### `PersistentBlockchain`

Persistent Blockchain: Database + Blockchain combined

*Line: 122*

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) Database {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `Database`

*Line: 23*

---

### `deinit`

```zig
pub fn deinit(self: *Database) void {
```

**Parameters:**

- `self`: `*Database`

*Line: 34*

---

### `storeBlock`

```zig
pub fn storeBlock(self: *Database, height: u64, block_data: []const u8) !void {
```

**Parameters:**

- `self`: `*Database`
- `height`: `u64`
- `block_data`: `[]const u8`

**Returns:** `!void`

*Line: 43*

---

### `getBlock`

```zig
pub fn getBlock(self: *const Database, height: u64) ?[]u8 {
```

**Parameters:**

- `self`: `*const Database`
- `height`: `u64`

**Returns:** `?[]u8`

*Line: 47*

---

### `getBlockCount`

```zig
pub fn getBlockCount(self: *const Database) u64 {
```

**Parameters:**

- `self`: `*const Database`

**Returns:** `u64`

*Line: 51*

---

### `indexTransaction`

```zig
pub fn indexTransaction(self: *Database, tx_hash: []const u8, block_height: u64, tx_index: u32) !void {
```

**Parameters:**

- `self`: `*Database`
- `tx_hash`: `[]const u8`
- `block_height`: `u64`
- `tx_index`: `u32`

**Returns:** `!void`

*Line: 56*

---

### `findTransaction`

```zig
pub fn findTransaction(self: *const Database, tx_hash: []const u8) ?storage_mod.TxLocation {
```

**Parameters:**

- `self`: `*const Database`
- `tx_hash`: `[]const u8`

**Returns:** `?storage_mod.TxLocation`

*Line: 60*

---

### `getTransactionCount`

```zig
pub fn getTransactionCount(self: *const Database) u64 {
```

**Parameters:**

- `self`: `*const Database`

**Returns:** `u64`

*Line: 64*

---

### `updateBalance`

```zig
pub fn updateBalance(self: *Database, address: []const u8, balance: u64) !void {
```

**Parameters:**

- `self`: `*Database`
- `address`: `[]const u8`
- `balance`: `u64`

**Returns:** `!void`

*Line: 69*

---

### `getBalance`

```zig
pub fn getBalance(self: *const Database, address: []const u8) ?u64 {
```

**Parameters:**

- `self`: `*const Database`
- `address`: `[]const u8`

**Returns:** `?u64`

*Line: 73*

---

### `getAddressCount`

```zig
pub fn getAddressCount(self: *const Database) usize {
```

**Parameters:**

- `self`: `*const Database`

**Returns:** `usize`

*Line: 77*

---

### `saveCheckpoint`

```zig
pub fn saveCheckpoint(self: *Database, state_data: []const u8) !u32 {
```

**Parameters:**

- `self`: `*Database`
- `state_data`: `[]const u8`

**Returns:** `!u32`

*Line: 82*

---

### `loadCheckpoint`

```zig
pub fn loadCheckpoint(self: *const Database, checkpoint_num: u32) ?[]u8 {
```

**Parameters:**

- `self`: `*const Database`
- `checkpoint_num`: `u32`

**Returns:** `?[]u8`

*Line: 86*

---

### `loadLatestCheckpoint`

```zig
pub fn loadLatestCheckpoint(self: *const Database) ?[]u8 {
```

**Parameters:**

- `self`: `*const Database`

**Returns:** `?[]u8`

*Line: 90*

---

### `setMetadata`

```zig
pub fn setMetadata(self: *Database, key: []const u8, value: []const u8) !void {
```

**Parameters:**

- `self`: `*Database`
- `key`: `[]const u8`
- `value`: `[]const u8`

**Returns:** `!void`

*Line: 95*

---

### `getMetadata`

```zig
pub fn getMetadata(self: *const Database, key: []const u8) ?[]u8 {
```

**Parameters:**

- `self`: `*const Database`
- `key`: `[]const u8`

**Returns:** `?[]u8`

*Line: 99*

---

### `getStats`

```zig
pub fn getStats(self: *const Database) DatabaseStats {
```

**Parameters:**

- `self`: `*const Database`

**Returns:** `DatabaseStats`

*Line: 104*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) PersistentBlockchain {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `PersistentBlockchain`

*Line: 126*

---

### `deinit`

```zig
pub fn deinit(self: *PersistentBlockchain) void {
```

**Parameters:**

- `self`: `*PersistentBlockchain`

*Line: 133*

---

### `loadFromDisk`

Incarca database din fisier (format binar simplu, fara dependente externe)
Format fisier: [magic:4][version:1][block_count:4]
per bloc: [height:8][data_len:4][data...]
[addr_count:4]
per adresa: [addr_len:1][addr...][balance:8]

```zig
pub fn loadFromDisk(allocator: std.mem.Allocator, path: []const u8) !PersistentBlockchain {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `path`: `[]const u8`

**Returns:** `!PersistentBlockchain`

*Line: 142*

---

### `saveToDisk`

Salveaza database pe disc (format binar simplu, atomic via tmp+rename)

```zig
pub fn saveToDisk(self: *PersistentBlockchain, path: []const u8) !void {
```

**Parameters:**

- `self`: `*PersistentBlockchain`
- `path`: `[]const u8`

**Returns:** `!void`

*Line: 213*

---

### `saveBlockchain`

Salveaza blockchain-ul activ (bc) pe disc — inlocuieste saveToDisk vechi
Format fisier: [magic:4][version:1][block_count:4]
per bloc: [height:8][data_len:4][data...]   (data = "index|ts|nonce|prev_hash|hash")
[addr_count:4]
per adresa: [addr_len:1][addr...][balance:8]

```zig
pub fn saveBlockchain(self: *PersistentBlockchain, bc: *const blockchain_mod.Blockchain, path: []const u8) !void {
```

**Parameters:**

- `self`: `*PersistentBlockchain`
- `bc`: `*const blockchain_mod.Blockchain`
- `path`: `[]const u8`

**Returns:** `!void`

*Line: 278*

---

### `restoreInto`

Reincarca blockchain-ul din disc in bc (apelat dupa buildBlockchain/genesis)
Adauga blocurile salvate in chain si reface balantele

```zig
pub fn restoreInto(self: *PersistentBlockchain, bc: *blockchain_mod.Blockchain, path: []const u8) !void {
```

**Parameters:**

- `self`: `*PersistentBlockchain`
- `bc`: `*blockchain_mod.Blockchain`
- `path`: `[]const u8`

**Returns:** `!void`

*Line: 340*

---

### `appendBlock`

Append un singur bloc nou la sfarsitul fisierului — O(1), fara rescriere completa.
Apelat la fiecare bloc minat pentru sync continuu chain→db.
Format append: [height:8][data_len:4][data...]
La final actualizeaza block_count in header (offset 5, 4 bytes).

```zig
pub fn appendBlock(self: *PersistentBlockchain, bc: *const blockchain_mod.Blockchain, path: []const u8) !void {
```

**Parameters:**

- `self`: `*PersistentBlockchain`
- `bc`: `*const blockchain_mod.Blockchain`
- `path`: `[]const u8`

**Returns:** `!void`

*Line: 471*

---

### `compact`

Compact — sterge blocuri vechi pastrand ultimele N
Implementare curenta: file-based. La scale se poate inlocui cu RocksDB/LevelDB.

```zig
pub fn compact(self: *PersistentBlockchain) !void {
```

**Parameters:**

- `self`: `*PersistentBlockchain`

**Returns:** `!void`

*Line: 597*

---

### `checkpoint`

Checkpoint entire blockchain state

```zig
pub fn checkpoint(self: *PersistentBlockchain) !u32 {
```

**Parameters:**

- `self`: `*PersistentBlockchain`

**Returns:** `!u32`

*Line: 602*

---

### `recoverFromCheckpoint`

Recover from checkpoint

```zig
pub fn recoverFromCheckpoint(self: *PersistentBlockchain, checkpoint_num: u32) bool {
```

**Parameters:**

- `self`: `*PersistentBlockchain`
- `checkpoint_num`: `u32`

**Returns:** `bool`

*Line: 616*

---

### `getStats`

Get database statistics

```zig
pub fn getStats(self: *const PersistentBlockchain) DatabaseStats {
```

**Parameters:**

- `self`: `*const PersistentBlockchain`

**Returns:** `DatabaseStats`

*Line: 622*

---

