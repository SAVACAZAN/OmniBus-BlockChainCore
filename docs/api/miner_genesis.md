# Module: `miner_genesis`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `MinerWallet`

Wallet simplu pentru geneza (adresa + balance, fara cheie privata completa)

*Line: 8*

### `GenesisAllocation`

Genesis Block Token Distribution

*Line: 71*

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, miner_id: u32, allocated_tokens: u64) !MinerWallet {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `miner_id`: `u32`
- `allocated_tokens`: `u64`

**Returns:** `!MinerWallet`

*Line: 17*

---

### `getPrimaryAddress`

```zig
pub fn getPrimaryAddress(self: *const MinerWallet) []const u8 {
```

**Parameters:**

- `self`: `*const MinerWallet`

**Returns:** `[]const u8`

*Line: 34*

---

### `getBalance`

```zig
pub fn getBalance(self: *const MinerWallet) u64 {
```

**Parameters:**

- `self`: `*const MinerWallet`

**Returns:** `u64`

*Line: 38*

---

### `addMiningReward`

```zig
pub fn addMiningReward(self: *MinerWallet, reward: u64) void {
```

**Parameters:**

- `self`: `*MinerWallet`
- `reward`: `u64`

*Line: 42*

---

### `recordBlockFound`

```zig
pub fn recordBlockFound(self: *MinerWallet) void {
```

**Parameters:**

- `self`: `*MinerWallet`

*Line: 47*

---

### `print`

```zig
pub fn print(self: *const MinerWallet) void {
```

**Parameters:**

- `self`: `*const MinerWallet`

*Line: 51*

---

### `deinit`

```zig
pub fn deinit(self: *MinerWallet) void {
```

**Parameters:**

- `self`: `*MinerWallet`

*Line: 64*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, miners_count: u32) !GenesisAllocation {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `miners_count`: `u32`

**Returns:** `!GenesisAllocation`

*Line: 78*

---

### `generateMinerWallets`

```zig
pub fn generateMinerWallets(self: *GenesisAllocation) !void {
```

**Parameters:**

- `self`: `*GenesisAllocation`

**Returns:** `!void`

*Line: 92*

---

### `getWallet`

```zig
pub fn getWallet(self: *const GenesisAllocation, miner_id: u32) ?*const MinerWallet {
```

**Parameters:**

- `self`: `*const GenesisAllocation`
- `miner_id`: `u32`

**Returns:** `?*const MinerWallet`

*Line: 115*

---

### `getTotalAllocated`

```zig
pub fn getTotalAllocated(self: *const GenesisAllocation) u64 {
```

**Parameters:**

- `self`: `*const GenesisAllocation`

**Returns:** `u64`

*Line: 122*

---

### `printSummary`

```zig
pub fn printSummary(self: *const GenesisAllocation) void {
```

**Parameters:**

- `self`: `*const GenesisAllocation`

*Line: 128*

---

### `deinit`

```zig
pub fn deinit(self: *GenesisAllocation) void {
```

**Parameters:**

- `self`: `*GenesisAllocation`

*Line: 147*

---

