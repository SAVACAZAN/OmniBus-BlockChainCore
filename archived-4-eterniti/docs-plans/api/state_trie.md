# Module: `state_trie`

> Merkle Patricia Trie for account state — O(log n) lookups, cryptographic proofs, 50MB vs 1.6TB for 1M+ accounts.

**Source:** `core/state_trie.zig` | **Lines:** 234 | **Functions:** 14 | **Structs:** 3 | **Tests:** 5

---

## Contents

### Structs
- [`AccountState`](#accountstate) — Account state (replaces needing to store all transactions)
- [`StateTrie`](#statetrie) — State Trie - merkle tree of account states
Instead of storing all transactions, ...
- [`StateSnapshot`](#statesnapshot) — State snapshot for checkpointing

### Functions
- [`hash()`](#hash) — Checks whether the h condition is true.
- [`print()`](#print) — Performs the print operation on the state_trie module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`updateBalance()`](#updatebalance) — Update account balance
- [`incrementNonce()`](#incrementnonce) — Increment nonce (for transaction sequencing)
- [`getBalance()`](#getbalance) — Get account balance
- [`getNonce()`](#getnonce) — Get account nonce
- [`calculateRootHash()`](#calculateroothash) — Calculate root hash (merkle root of all accounts)
- [`getAccountCount()`](#getaccountcount) — Get account count
- [`estimateStorageSize()`](#estimatestoragesize) — Estimate storage size
- [`printStats()`](#printstats) — Print statistics
- [`getAllAccounts()`](#getallaccounts) — Get all accounts (for verification)
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`print()`](#print) — Performs the print operation on the state_trie module.

---

## Structs

### `AccountState`

Account state (replaces needing to store all transactions)

| Field | Type | Description |
|-------|------|-------------|
| `address` | `[20]u8` | Address |
| `balance` | `u64` | Balance |
| `nonce` | `u32` | Nonce |
| `last_updated_block` | `u32` | Last_updated_block |
| `flags` | `u8` | Flags |

*Defined at line 5*

---

### `StateTrie`

State Trie - merkle tree of account states
Instead of storing all transactions, store only current state
~50 MB for 1M+ accounts vs 1.6 TB for all transaction history!

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `accounts` | `std.AutoHashMap([20]u8` | Accounts |

*Defined at line 41*

---

### `StateSnapshot`

State snapshot for checkpointing

| Field | Type | Description |
|-------|------|-------------|
| `block_height` | `u32` | Block_height |
| `root_hash` | `[32]u8` | Root_hash |
| `timestamp` | `i64` | Timestamp |
| `account_count` | `usize` | Account_count |
| `size_bytes` | `u64` | Size_bytes |

*Defined at line 157*

---

## Functions

### `hash()`

Checks whether the h condition is true.

```zig
pub fn hash(self: *const AccountState) [32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const AccountState` | The instance |

**Returns:** `[32]u8`

*Defined at line 12*

---

### `print()`

Performs the print operation on the state_trie module.

```zig
pub fn print(self: *const AccountState) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const AccountState` | The instance |

*Defined at line 30*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) StateTrie {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `StateTrie`

*Defined at line 47*

---

### `updateBalance()`

Update account balance

```zig
pub fn updateBalance(self: *StateTrie, address: [20]u8, new_balance: u64, block_height: u32) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StateTrie` | The instance |
| `address` | `[20]u8` | Address |
| `new_balance` | `u64` | New_balance |
| `block_height` | `u32` | Block_height |

**Returns:** `!void`

*Defined at line 55*

---

### `incrementNonce()`

Increment nonce (for transaction sequencing)

```zig
pub fn incrementNonce(self: *StateTrie, address: [20]u8, block_height: u32) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StateTrie` | The instance |
| `address` | `[20]u8` | Address |
| `block_height` | `u32` | Block_height |

**Returns:** `!void`

*Defined at line 68*

---

### `getBalance()`

Get account balance

```zig
pub fn getBalance(self: *const StateTrie, address: [20]u8) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateTrie` | The instance |
| `address` | `[20]u8` | Address |

**Returns:** `u64`

*Defined at line 81*

---

### `getNonce()`

Get account nonce

```zig
pub fn getNonce(self: *const StateTrie, address: [20]u8) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateTrie` | The instance |
| `address` | `[20]u8` | Address |

**Returns:** `u32`

*Defined at line 87*

---

### `calculateRootHash()`

Calculate root hash (merkle root of all accounts)

```zig
pub fn calculateRootHash(self: *const StateTrie) [32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateTrie` | The instance |

**Returns:** `[32]u8`

*Defined at line 93*

---

### `getAccountCount()`

Get account count

```zig
pub fn getAccountCount(self: *const StateTrie) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateTrie` | The instance |

**Returns:** `usize`

*Defined at line 108*

---

### `estimateStorageSize()`

Estimate storage size

```zig
pub fn estimateStorageSize(self: *const StateTrie) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateTrie` | The instance |

**Returns:** `u64`

*Defined at line 113*

---

### `printStats()`

Print statistics

```zig
pub fn printStats(self: *const StateTrie) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateTrie` | The instance |

*Defined at line 119*

---

### `getAllAccounts()`

Get all accounts (for verification)

```zig
pub fn getAllAccounts(self: *const StateTrie, allocator: std.mem.Allocator) ![]AccountState {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateTrie` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]AccountState`

*Defined at line 140*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *StateTrie) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StateTrie` | The instance |

*Defined at line 151*

---

### `print()`

Performs the print operation on the state_trie module.

```zig
pub fn print(self: *const StateSnapshot) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StateSnapshot` | The instance |

*Defined at line 164*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
