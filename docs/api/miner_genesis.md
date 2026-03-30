# Module: `miner_genesis`

> Genesis miner allocation — initial miner addresses, pre-mine distribution for bootstrap.

**Source:** `core/miner_genesis.zig` | **Lines:** 208 | **Functions:** 13 | **Structs:** 2 | **Tests:** 6

---

## Contents

### Structs
- [`MinerWallet`](#minerwallet) — Wallet simplu pentru geneza (adresa + balance, fara cheie privata completa)
- [`GenesisAllocation`](#genesisallocation) — Genesis Block Token Distribution

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`getPrimaryAddress()`](#getprimaryaddress) — Returns the current primary address.
- [`getBalance()`](#getbalance) — Returns the current balance.
- [`addMiningReward()`](#addminingreward) — Adds a new mining reward to the collection.
- [`recordBlockFound()`](#recordblockfound) — Performs the record block found operation on the miner_genesis module.
- [`print()`](#print) — Performs the print operation on the miner_genesis module.
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`generateMinerWallets()`](#generateminerwallets) — Executes mining operation — finds valid nonce for the next block.
- [`getWallet()`](#getwallet) — Returns the wallet for the given miner_id.
- [`getTotalAllocated()`](#gettotalallocated) — Returns the current total allocated.
- [`printSummary()`](#printsummary) — Performs the print summary operation on the miner_genesis module.
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.

---

## Structs

### `MinerWallet`

Wallet simplu pentru geneza (adresa + balance, fara cheie privata completa)

| Field | Type | Description |
|-------|------|-------------|
| `miner_id` | `u32` | Miner_id |
| `miner_name` | `[]const u8` | Miner_name |
| `address` | `[]const u8` | Address |
| `balance` | `u64` | Balance |
| `mining_reward` | `u64` | Mining_reward |
| `block_contribution` | `u32` | Block_contribution |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 8*

---

### `GenesisAllocation`

Genesis Block Token Distribution

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `miner_wallets` | `array_list.Managed(MinerWallet)` | Miner_wallets |
| `total_supply` | `u64` | Total_supply |
| `miners_count` | `u32` | Miners_count |
| `allocation_per_miner` | `u64` | Allocation_per_miner |

*Defined at line 71*

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, miner_id: u32, allocated_tokens: u64) !MinerWallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `miner_id` | `u32` | Miner_id |
| `allocated_tokens` | `u64` | Allocated_tokens |

**Returns:** `!MinerWallet`

*Defined at line 17*

---

### `getPrimaryAddress()`

Returns the current primary address.

```zig
pub fn getPrimaryAddress(self: *const MinerWallet) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerWallet` | The instance |

**Returns:** `[]const u8`

*Defined at line 34*

---

### `getBalance()`

Returns the current balance.

```zig
pub fn getBalance(self: *const MinerWallet) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerWallet` | The instance |

**Returns:** `u64`

*Defined at line 38*

---

### `addMiningReward()`

Adds a new mining reward to the collection.

```zig
pub fn addMiningReward(self: *MinerWallet, reward: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWallet` | The instance |
| `reward` | `u64` | Reward |

*Defined at line 42*

---

### `recordBlockFound()`

Performs the record block found operation on the miner_genesis module.

```zig
pub fn recordBlockFound(self: *MinerWallet) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWallet` | The instance |

*Defined at line 47*

---

### `print()`

Performs the print operation on the miner_genesis module.

```zig
pub fn print(self: *const MinerWallet) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerWallet` | The instance |

*Defined at line 51*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *MinerWallet) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWallet` | The instance |

*Defined at line 64*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, miners_count: u32) !GenesisAllocation {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `miners_count` | `u32` | Miners_count |

**Returns:** `!GenesisAllocation`

*Defined at line 78*

---

### `generateMinerWallets()`

Executes mining operation — finds valid nonce for the next block.

```zig
pub fn generateMinerWallets(self: *GenesisAllocation) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*GenesisAllocation` | The instance |

**Returns:** `!void`

*Defined at line 92*

---

### `getWallet()`

Returns the wallet for the given miner_id.

```zig
pub fn getWallet(self: *const GenesisAllocation, miner_id: u32) ?*const MinerWallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const GenesisAllocation` | The instance |
| `miner_id` | `u32` | Miner_id |

**Returns:** `?*const MinerWallet`

*Defined at line 115*

---

### `getTotalAllocated()`

Returns the current total allocated.

```zig
pub fn getTotalAllocated(self: *const GenesisAllocation) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const GenesisAllocation` | The instance |

**Returns:** `u64`

*Defined at line 122*

---

### `printSummary()`

Performs the print summary operation on the miner_genesis module.

```zig
pub fn printSummary(self: *const GenesisAllocation) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const GenesisAllocation` | The instance |

*Defined at line 128*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *GenesisAllocation) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*GenesisAllocation` | The instance |

*Defined at line 147*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
