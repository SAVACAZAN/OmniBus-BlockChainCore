# Module: `blockchain`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Blockchain`

*Line: 77*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Block` | auto | `block_mod.Block` |
| `Transaction` | auto | `transaction_mod.Transaction` |
| `BLOCK_REWARD_SAT` | auto | `u64 = 8_333_333` |
| `HALVING_INTERVAL` | auto | `u64 = 126_144_000` |
| `MAX_SUPPLY_SAT` | auto | `u64 = 21_000_000_000_000_000` |
| `COINBASE_MATURITY` | auto | `u32 = 100` |
| `DUST_THRESHOLD_SAT` | auto | `u64 = 100` |
| `RETARGET_INTERVAL` | auto | `u64 = 2016` |
| `TARGET_BLOCK_TIME_S` | auto | `i64 = 1` |
| `TARGET_INTERVAL_S` | auto | `i64 = @intCast(RETARGET_INTERVAL)` |
| `MIN_DIFFICULTY` | auto | `u32 = 1` |
| `MAX_DIFFICULTY` | auto | `u32 = 256` |
| `FEE_BURN_PCT` | auto | `u64 = 50` |
| `TX_MIN_FEE` | auto | `u64 = 1` |

## Functions

### `retargetDifficulty`

Calculeaza noua dificultate dupa un interval de retarget.
Formula: new_difficulty = old_difficulty * TARGET_INTERVAL / actual_time
Clamped la ±4x fata de dificultatea anterioara (ca Bitcoin) si [MIN, MAX].

```zig
pub fn retargetDifficulty(old_difficulty: u32, actual_time_s: i64) u32 {
```

**Parameters:**

- `old_difficulty`: `u32`
- `actual_time_s`: `i64`

**Returns:** `u32`

*Line: 55*

---

### `blockRewardAt`

```zig
pub fn blockRewardAt(height: u64) u64 {
```

**Parameters:**

- `height`: `u64`

**Returns:** `u64`

*Line: 71*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) !Blockchain {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `!Blockchain`

*Line: 88*

---

### `deinit`

```zig
pub fn deinit(self: *Blockchain) void {
```

**Parameters:**

- `self`: `*Blockchain`

*Line: 114*

---

### `getAddressBalance`

Returneaza balanta unei adrese (0 daca nu exista)

```zig
pub fn getAddressBalance(self: *const Blockchain, address: []const u8) u64 {
```

**Parameters:**

- `self`: `*const Blockchain`
- `address`: `[]const u8`

**Returns:** `u64`

*Line: 134*

---

### `creditBalance`

Adauga reward la balanta minerului

```zig
pub fn creditBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
```

**Parameters:**

- `self`: `*Blockchain`
- `address`: `[]const u8`
- `amount`: `u64`

**Returns:** `!void`

*Line: 139*

---

### `debitBalance`

Scade din balanta (pentru tranzactii)

```zig
pub fn debitBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
```

**Parameters:**

- `self`: `*Blockchain`
- `address`: `[]const u8`
- `amount`: `u64`

**Returns:** `!void`

*Line: 145*

---

### `addTransaction`

```zig
pub fn addTransaction(self: *Blockchain, tx: Transaction) !void {
```

**Parameters:**

- `self`: `*Blockchain`
- `tx`: `Transaction`

**Returns:** `!void`

*Line: 151*

---

### `getNextNonce`

Returneaza urmatorul nonce asteptat pentru o adresa (0 daca nu exista)

```zig
pub fn getNextNonce(self: *const Blockchain, address: []const u8) u64 {
```

**Parameters:**

- `self`: `*const Blockchain`
- `address`: `[]const u8`

**Returns:** `u64`

*Line: 161*

---

### `validateTransaction`

```zig
pub fn validateTransaction(self: *Blockchain, tx: *const Transaction) !bool {
```

**Parameters:**

- `self`: `*Blockchain`
- `tx`: `*const Transaction`

**Returns:** `!bool`

*Line: 165*

---

### `mineBlock`

```zig
pub fn mineBlock(self: *Blockchain) !Block {
```

**Parameters:**

- `self`: `*Blockchain`

**Returns:** `!Block`

*Line: 206*

---

### `mineBlockForMiner`

Mine block + acorda reward minerului + proceseaza TX-urile din mempool

```zig
pub fn mineBlockForMiner(self: *Blockchain, miner_address: []const u8) !Block {
```

**Parameters:**

- `self`: `*Blockchain`
- `miner_address`: `[]const u8`

**Returns:** `!Block`

*Line: 211*

---

### `calculateBlockHash`

Calculate block hash as 64-char hex string (delegates to shared hex_utils)

```zig
pub fn calculateBlockHash(self: *Blockchain, block: *const Block) ![]const u8 {
```

**Parameters:**

- `self`: `*Blockchain`
- `block`: `*const Block`

**Returns:** `![]const u8`

*Line: 294*

---

### `isValidHash`

Check if hash meets difficulty (delegates to shared hex_utils)

```zig
pub fn isValidHash(self: *Blockchain, hash: []const u8) !bool {
```

**Parameters:**

- `self`: `*Blockchain`
- `hash`: `[]const u8`

**Returns:** `!bool`

*Line: 308*

---

### `getBlock`

```zig
pub fn getBlock(self: *Blockchain, index: u32) ?Block {
```

**Parameters:**

- `self`: `*Blockchain`
- `index`: `u32`

**Returns:** `?Block`

*Line: 312*

---

### `getLatestBlock`

```zig
pub fn getLatestBlock(self: *Blockchain) Block {
```

**Parameters:**

- `self`: `*Blockchain`

**Returns:** `Block`

*Line: 319*

---

### `getBlockCount`

```zig
pub fn getBlockCount(self: *Blockchain) u32 {
```

**Parameters:**

- `self`: `*Blockchain`

**Returns:** `u32`

*Line: 323*

---

