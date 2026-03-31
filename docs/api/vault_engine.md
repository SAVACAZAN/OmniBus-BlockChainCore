# Module: `vault_engine`

> Mnemonic vault — BIP-39 seed storage, encryption, secure derivation.

**Source:** `core/vault_engine.zig` | **Lines:** 314 | **Functions:** 8 | **Structs:** 2 | **Tests:** 11

---

## Contents

### Structs
- [`VaultPosition`](#vaultposition) — O pozitie in Vault (un depozit de la un user)
- [`VaultEngine`](#vaultengine) — Data structure for vault engine. Fields include: allocator, positions, next_pos_...

### Constants
- [4 constants defined](#constants)

### Functions
- [`profitSat()`](#profitsat) — Profitul curent (0 daca nav < deposit)
- [`hasDoubled()`](#hasdoubled) — A atins dublarea?
- [`roiPct()`](#roipct) — Return on Investment in procente (scaled x100)
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`findPosition()`](#findposition) — Searches for position matching the given criteria.
- [`activeCount()`](#activecount) — Performs the active count operation on the vault_engine module.
- [`printStatus()`](#printstatus) — Performs the print status operation on the vault_engine module.

---

## Structs

### `VaultPosition`

O pozitie in Vault (un depozit de la un user)

| Field | Type | Description |
|-------|------|-------------|
| `position_id` | `u64` | Position_id |
| `owner` | `[32]u8` | Owner |
| `anchor_addr` | `[32]u8` | Anchor_addr |
| `deposit_sat` | `u64` | Deposit_sat |
| `current_nav_sat` | `u64` | Current_nav_sat |
| `status` | `VaultPositionStatus` | Status |
| `opened_block` | `u64` | Opened_block |
| `closed_block` | `u64` | Closed_block |

*Defined at line 39*

---

### `VaultEngine`

Data structure for vault engine. Fields include: allocator, positions, next_pos_id, total_deposits_sat, total_returned_sat.

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `positions` | `std.array_list.Managed(VaultPosition)` | Positions |
| `next_pos_id` | `u64` | Next_pos_id |
| `total_deposits_sat` | `u64` | Total_deposits_sat |
| `total_returned_sat` | `u64` | Total_returned_sat |
| `total_ubi_sat` | `u64` | Total_ubi_sat |
| `total_fee_sat` | `u64` | Total_fee_sat |
| `owner` | `[32]u8` | Owner |
| `anchor_addr` | `[32]u8` | Anchor_addr |
| `amount_sat` | `u64` | Amount_sat |
| `user_level` | `u8` | User_level |

*Defined at line 71*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `VAULT_MIN_LEVEL` | `u8 = 100` | V a u l t_ m i n_ l e v e l |
| `DOUBLE_FACTOR_PCT` | `u64 = 200` | D o u b l e_ f a c t o r_ p c t |
| `VAULT_PROTOCOL_FEE_PCT` | `u64 = 10` | V a u l t_ p r o t o c o l_ f e e_ p c t |
| `VaultPositionStatus` | `enum(u8) {` | Vault position status |

---

## Functions

### `profitSat()`

Profitul curent (0 daca nav < deposit)

```zig
pub fn profitSat(self: *const VaultPosition) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const VaultPosition` | The instance |

**Returns:** `u64`

*Defined at line 50*

---

### `hasDoubled()`

A atins dublarea?

```zig
pub fn hasDoubled(self: *const VaultPosition) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const VaultPosition` | The instance |

**Returns:** `bool`

*Defined at line 56*

---

### `roiPct()`

Return on Investment in procente (scaled x100)

```zig
pub fn roiPct(self: *const VaultPosition) i64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const VaultPosition` | The instance |

**Returns:** `i64`

*Defined at line 61*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) VaultEngine {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `VaultEngine`

*Defined at line 88*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *VaultEngine) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*VaultEngine` | The instance |

*Defined at line 100*

---

### `findPosition()`

Searches for position matching the given criteria.

```zig
pub fn findPosition(self: *VaultEngine, position_id: u64) !*VaultPosition {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*VaultEngine` | The instance |
| `position_id` | `u64` | Position_id |

**Returns:** `!*VaultPosition`

*Defined at line 190*

---

### `activeCount()`

Performs the active count operation on the vault_engine module.

```zig
pub fn activeCount(self: *const VaultEngine) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const VaultEngine` | The instance |

**Returns:** `usize`

*Defined at line 197*

---

### `printStatus()`

Performs the print status operation on the vault_engine module.

```zig
pub fn printStatus(self: *const VaultEngine) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const VaultEngine` | The instance |

*Defined at line 205*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
