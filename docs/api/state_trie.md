# Module: `state_trie`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `AccountState`

Account state (replaces needing to store all transactions)

*Line: 5*

### `StateTrie`

State Trie - merkle tree of account states
Instead of storing all transactions, store only current state
~50 MB for 1M+ accounts vs 1.6 TB for all transaction history!

*Line: 41*

### `StateSnapshot`

State snapshot for checkpointing

*Line: 157*

## Functions

### `hash`

```zig
pub fn hash(self: *const AccountState) [32]u8 {
```

**Parameters:**

- `self`: `*const AccountState`

**Returns:** `[32]u8`

*Line: 12*

---

### `print`

```zig
pub fn print(self: *const AccountState) void {
```

**Parameters:**

- `self`: `*const AccountState`

*Line: 30*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) StateTrie {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `StateTrie`

*Line: 47*

---

### `updateBalance`

Update account balance

```zig
pub fn updateBalance(self: *StateTrie, address: [20]u8, new_balance: u64, block_height: u32) !void {
```

**Parameters:**

- `self`: `*StateTrie`
- `address`: `[20]u8`
- `new_balance`: `u64`
- `block_height`: `u32`

**Returns:** `!void`

*Line: 55*

---

### `incrementNonce`

Increment nonce (for transaction sequencing)

```zig
pub fn incrementNonce(self: *StateTrie, address: [20]u8, block_height: u32) !void {
```

**Parameters:**

- `self`: `*StateTrie`
- `address`: `[20]u8`
- `block_height`: `u32`

**Returns:** `!void`

*Line: 68*

---

### `getBalance`

Get account balance

```zig
pub fn getBalance(self: *const StateTrie, address: [20]u8) u64 {
```

**Parameters:**

- `self`: `*const StateTrie`
- `address`: `[20]u8`

**Returns:** `u64`

*Line: 81*

---

### `getNonce`

Get account nonce

```zig
pub fn getNonce(self: *const StateTrie, address: [20]u8) u32 {
```

**Parameters:**

- `self`: `*const StateTrie`
- `address`: `[20]u8`

**Returns:** `u32`

*Line: 87*

---

### `calculateRootHash`

Calculate root hash (merkle root of all accounts)

```zig
pub fn calculateRootHash(self: *const StateTrie) [32]u8 {
```

**Parameters:**

- `self`: `*const StateTrie`

**Returns:** `[32]u8`

*Line: 93*

---

### `getAccountCount`

Get account count

```zig
pub fn getAccountCount(self: *const StateTrie) usize {
```

**Parameters:**

- `self`: `*const StateTrie`

**Returns:** `usize`

*Line: 108*

---

### `estimateStorageSize`

Estimate storage size

```zig
pub fn estimateStorageSize(self: *const StateTrie) u64 {
```

**Parameters:**

- `self`: `*const StateTrie`

**Returns:** `u64`

*Line: 113*

---

### `printStats`

Print statistics

```zig
pub fn printStats(self: *const StateTrie) void {
```

**Parameters:**

- `self`: `*const StateTrie`

*Line: 119*

---

### `getAllAccounts`

Get all accounts (for verification)

```zig
pub fn getAllAccounts(self: *const StateTrie, allocator: std.mem.Allocator) ![]AccountState {
```

**Parameters:**

- `self`: `*const StateTrie`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]AccountState`

*Line: 140*

---

### `deinit`

```zig
pub fn deinit(self: *StateTrie) void {
```

**Parameters:**

- `self`: `*StateTrie`

*Line: 151*

---

### `print`

```zig
pub fn print(self: *const StateSnapshot) void {
```

**Parameters:**

- `self`: `*const StateSnapshot`

*Line: 164*

---

