# Module: `vault_engine`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `VaultPosition`

O pozitie in Vault (un depozit de la un user)

*Line: 39*

### `VaultEngine`

*Line: 71*

## Constants

| Name | Type | Value |
|------|------|-------|
| `VAULT_MIN_LEVEL` | auto | `u8 = 100` |
| `DOUBLE_FACTOR_PCT` | auto | `u64 = 200` |
| `VAULT_PROTOCOL_FEE_PCT` | auto | `u64 = 10` |
| `VaultPositionStatus` | auto | `enum(u8) {` |

## Functions

### `profitSat`

Profitul curent (0 daca nav < deposit)

```zig
pub fn profitSat(self: *const VaultPosition) u64 {
```

**Parameters:**

- `self`: `*const VaultPosition`

**Returns:** `u64`

*Line: 50*

---

### `hasDoubled`

A atins dublarea?

```zig
pub fn hasDoubled(self: *const VaultPosition) bool {
```

**Parameters:**

- `self`: `*const VaultPosition`

**Returns:** `bool`

*Line: 56*

---

### `roiPct`

Return on Investment in procente (scaled x100)

```zig
pub fn roiPct(self: *const VaultPosition) i64 {
```

**Parameters:**

- `self`: `*const VaultPosition`

**Returns:** `i64`

*Line: 61*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) VaultEngine {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `VaultEngine`

*Line: 88*

---

### `deinit`

```zig
pub fn deinit(self: *VaultEngine) void {
```

**Parameters:**

- `self`: `*VaultEngine`

*Line: 100*

---

### `findPosition`

```zig
pub fn findPosition(self: *VaultEngine, position_id: u64) !*VaultPosition {
```

**Parameters:**

- `self`: `*VaultEngine`
- `position_id`: `u64`

**Returns:** `!*VaultPosition`

*Line: 190*

---

### `activeCount`

```zig
pub fn activeCount(self: *const VaultEngine) usize {
```

**Parameters:**

- `self`: `*const VaultEngine`

**Returns:** `usize`

*Line: 197*

---

### `printStatus`

```zig
pub fn printStatus(self: *const VaultEngine) void {
```

**Parameters:**

- `self`: `*const VaultEngine`

*Line: 205*

---

