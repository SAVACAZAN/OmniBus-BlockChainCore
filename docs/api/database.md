# Module: `database`

> Persistent storage — binary serialization of blockchain state to omnibus-chain.dat, atomic write (tmp → rename), append-only block storage.

**Source:** `core/database.zig` | **Lines:** 1172 | **Functions:** 28 | **Structs:** 3 | **Tests:** 11

---

## Contents

### Structs
- [`Database`](#database) — Database: Unified storage layer
Combines block, transaction, address, and checkp...
- [`DatabaseStats`](#databasestats) — Data structure for database stats. Fields include: total_blocks, total_transacti...
- [`PersistentBlockchain`](#persistentblockchain) — Persistent Blockchain: Database + Blockchain combined

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`storeBlock()`](#storeblock) — Performs the store block operation on the database module.
- [`getBlock()`](#getblock) — Returns the block for the given height.
- [`getBlockCount()`](#getblockcount) — Returns the current block count.
- [`indexTransaction()`](#indextransaction) — Performs the index transaction operation on the database module.
- [`findTransaction()`](#findtransaction) — Searches for transaction matching the given criteria.
- [`getTransactionCount()`](#gettransactioncount) — Returns the current transaction count.
- [`updateBalance()`](#updatebalance) — Updates the balance with new values.
- [`getBalance()`](#getbalance) — Returns the balance for the given address.
- [`getAddressCount()`](#getaddresscount) — Returns the current address count.
- [`saveCheckpoint()`](#savecheckpoint) — Saves checkpoint to persistent storage.
- [`loadCheckpoint()`](#loadcheckpoint) — Loads checkpoint from persistent storage.
- [`loadLatestCheckpoint()`](#loadlatestcheckpoint) — Loads latest checkpoint from persistent storage.
- [`setMetadata()`](#setmetadata) — Sets the metadata to the specified value.
- [`getMetadata()`](#getmetadata) — Returns the metadata for the given key.
- [`getStats()`](#getstats) — Returns the current stats.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`loadFromDisk()`](#loadfromdisk) — Incarca database din fisier (format binar simplu, fara dependente exte...
- [`saveToDisk()`](#savetodisk) — Salveaza database pe disc (format binar simplu, atomic via tmp+rename)
- [`saveBlockchain()`](#saveblockchain) — Salveaza blockchain-ul activ (bc) pe disc
Format v2: [magic:4][version...
- [`restoreInto()`](#restoreinto) — Reincarca blockchain-ul din disc in bc (apelat dupa buildBlockchain/ge...
- [`appendBlock()`](#appendblock) — Append un singur bloc nou la sfarsitul fisierului — for v1 compat.
For...
- [`compact()`](#compact) — Compact — sterge blocuri vechi pastrand ultimele N
- [`checkpoint()`](#checkpoint) — Checkpoint entire blockchain state
- [`recoverFromCheckpoint()`](#recoverfromcheckpoint) — Recover from checkpoint
- [`getStats()`](#getstats) — Get database statistics

---

## Structs

### `Database`

Database: Unified storage layer
Combines block, transaction, address, and checkpoint storage

| Field | Type | Description |
|-------|------|-------------|
| `blocks` | `BlockStore` | Blocks |
| `transactions` | `TransactionIndex` | Transactions |
| `addresses` | `AddressIndex` | Addresses |
| `checkpoints` | `StateCheckpoint` | Checkpoints |
| `metadata` | `KeyValueStore` | Metadata |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 20*

---

### `DatabaseStats`

Data structure for database stats. Fields include: total_blocks, total_transactions, total_addresses, total_checkpoints.

| Field | Type | Description |
|-------|------|-------------|
| `total_blocks` | `u64` | Total_blocks |
| `total_transactions` | `u64` | Total_transactions |
| `total_addresses` | `usize` | Total_addresses |
| `total_checkpoints` | `u32` | Total_checkpoints |

*Defined at line 119*

---

### `PersistentBlockchain`

Persistent Blockchain: Database + Blockchain combined

| Field | Type | Description |
|-------|------|-------------|
| `db` | `Database` | Db |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 151*

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) Database {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `Database`

*Defined at line 28*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *Database) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Database` | The instance |

*Defined at line 39*

---

### `storeBlock()`

Performs the store block operation on the database module.

```zig
pub fn storeBlock(self: *Database, height: u64, block_data: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Database` | The instance |
| `height` | `u64` | Height |
| `block_data` | `[]const u8` | Block_data |

**Returns:** `!void`

*Defined at line 48*

---

### `getBlock()`

Returns the block for the given height.

```zig
pub fn getBlock(self: *const Database, height: u64) ?[]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |
| `height` | `u64` | Height |

**Returns:** `?[]u8`

*Defined at line 52*

---

### `getBlockCount()`

Returns the current block count.

```zig
pub fn getBlockCount(self: *const Database) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |

**Returns:** `u64`

*Defined at line 56*

---

### `indexTransaction()`

Performs the index transaction operation on the database module.

```zig
pub fn indexTransaction(self: *Database, tx_hash: []const u8, block_height: u64, tx_index: u32) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Database` | The instance |
| `tx_hash` | `[]const u8` | Tx_hash |
| `block_height` | `u64` | Block_height |
| `tx_index` | `u32` | Tx_index |

**Returns:** `!void`

*Defined at line 61*

---

### `findTransaction()`

Searches for transaction matching the given criteria.

```zig
pub fn findTransaction(self: *const Database, tx_hash: []const u8) ?storage_mod.TxLocation {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |
| `tx_hash` | `[]const u8` | Tx_hash |

**Returns:** `?storage_mod.TxLocation`

*Defined at line 65*

---

### `getTransactionCount()`

Returns the current transaction count.

```zig
pub fn getTransactionCount(self: *const Database) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |

**Returns:** `u64`

*Defined at line 69*

---

### `updateBalance()`

Updates the balance with new values.

```zig
pub fn updateBalance(self: *Database, address: []const u8, balance: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Database` | The instance |
| `address` | `[]const u8` | Address |
| `balance` | `u64` | Balance |

**Returns:** `!void`

*Defined at line 74*

---

### `getBalance()`

Returns the balance for the given address.

```zig
pub fn getBalance(self: *const Database, address: []const u8) ?u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `?u64`

*Defined at line 78*

---

### `getAddressCount()`

Returns the current address count.

```zig
pub fn getAddressCount(self: *const Database) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |

**Returns:** `usize`

*Defined at line 82*

---

### `saveCheckpoint()`

Saves checkpoint to persistent storage.

```zig
pub fn saveCheckpoint(self: *Database, state_data: []const u8) !u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Database` | The instance |
| `state_data` | `[]const u8` | State_data |

**Returns:** `!u32`

*Defined at line 87*

---

### `loadCheckpoint()`

Loads checkpoint from persistent storage.

```zig
pub fn loadCheckpoint(self: *const Database, checkpoint_num: u32) ?[]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |
| `checkpoint_num` | `u32` | Checkpoint_num |

**Returns:** `?[]u8`

*Defined at line 91*

---

### `loadLatestCheckpoint()`

Loads latest checkpoint from persistent storage.

```zig
pub fn loadLatestCheckpoint(self: *const Database) ?[]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |

**Returns:** `?[]u8`

*Defined at line 95*

---

### `setMetadata()`

Sets the metadata to the specified value.

```zig
pub fn setMetadata(self: *Database, key: []const u8, value: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Database` | The instance |
| `key` | `[]const u8` | Key |
| `value` | `[]const u8` | Value |

**Returns:** `!void`

*Defined at line 100*

---

### `getMetadata()`

Returns the metadata for the given key.

```zig
pub fn getMetadata(self: *const Database, key: []const u8) ?[]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |
| `key` | `[]const u8` | Key |

**Returns:** `?[]u8`

*Defined at line 104*

---

### `getStats()`

Returns the current stats.

```zig
pub fn getStats(self: *const Database) DatabaseStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Database` | The instance |

**Returns:** `DatabaseStats`

*Defined at line 109*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) PersistentBlockchain {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `PersistentBlockchain`

*Defined at line 155*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *PersistentBlockchain) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PersistentBlockchain` | The instance |

*Defined at line 162*

---

### `loadFromDisk()`

Incarca database din fisier (format binar simplu, fara dependente externe)
Format fisier: [magic:4][version:1][block_count:4]
per bloc: [height:8][data_len:4][data...]
[addr_count:4]
per adresa: [addr_len:1][addr...][balance:8]

```zig
pub fn loadFromDisk(allocator: std.mem.Allocator, path: []const u8) !PersistentBlockchain {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `path` | `[]const u8` | Path |

**Returns:** `!PersistentBlockchain`

*Defined at line 171*

---

### `saveToDisk()`

Salveaza database pe disc (format binar simplu, atomic via tmp+rename)

```zig
pub fn saveToDisk(self: *PersistentBlockchain, path: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PersistentBlockchain` | The instance |
| `path` | `[]const u8` | Path |

**Returns:** `!void`

*Defined at line 242*

---

### `saveBlockchain()`

Salveaza blockchain-ul activ (bc) pe disc
Format v2: [magic:4][version:4]
[block_count:4] per bloc: [height:8][data_len:4][data...] [crc32:4]
[addr_count:4]  per adresa: [addr_len:1][addr...][balance:8] [crc32:4]
[nonce_count:4] per nonce: [addr_len:1][addr...][nonce:8] [crc32:4]
[tx_count:4]    per tx: [hash_len:1][hash...][height:8] [crc32:4]

```zig
pub fn saveBlockchain(self: *PersistentBlockchain, bc: *const blockchain_mod.Blockchain, path: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PersistentBlockchain` | The instance |
| `bc` | `*const blockchain_mod.Blockchain` | Bc |
| `path` | `[]const u8` | Path |

**Returns:** `!void`

*Defined at line 316*

---

### `restoreInto()`

Reincarca blockchain-ul din disc in bc (apelat dupa buildBlockchain/genesis)
Supports both v1 and v2 file formats. V2 adds CRC32 checksums per section.
Creates .bak backup before loading. Falls back to .bak if .dat is corrupt.

```zig
pub fn restoreInto(self: *PersistentBlockchain, bc: *blockchain_mod.Blockchain, path: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PersistentBlockchain` | The instance |
| `bc` | `*blockchain_mod.Blockchain` | Bc |
| `path` | `[]const u8` | Path |

**Returns:** `!void`

*Defined at line 486*

---

### `appendBlock()`

Append un singur bloc nou la sfarsitul fisierului — for v1 compat.
For v2, falls back to full saveBlockchain since sections have CRC32 trailers.

```zig
pub fn appendBlock(self: *PersistentBlockchain, bc: *const blockchain_mod.Blockchain, path: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PersistentBlockchain` | The instance |
| `bc` | `*const blockchain_mod.Blockchain` | Bc |
| `path` | `[]const u8` | Path |

**Returns:** `!void`

*Defined at line 808*

---

### `compact()`

Compact — sterge blocuri vechi pastrand ultimele N

```zig
pub fn compact(self: *PersistentBlockchain) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PersistentBlockchain` | The instance |

**Returns:** `!void`

*Defined at line 978*

---

### `checkpoint()`

Checkpoint entire blockchain state

```zig
pub fn checkpoint(self: *PersistentBlockchain) !u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PersistentBlockchain` | The instance |

**Returns:** `!u32`

*Defined at line 983*

---

### `recoverFromCheckpoint()`

Recover from checkpoint

```zig
pub fn recoverFromCheckpoint(self: *PersistentBlockchain, checkpoint_num: u32) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PersistentBlockchain` | The instance |
| `checkpoint_num` | `u32` | Checkpoint_num |

**Returns:** `bool`

*Defined at line 997*

---

### `getStats()`

Get database statistics

```zig
pub fn getStats(self: *const PersistentBlockchain) DatabaseStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PersistentBlockchain` | The instance |

**Returns:** `DatabaseStats`

*Defined at line 1003*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
