# Module: `ubi_distributor`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `UbiBeneficiary`

*Line: 37*

### `UbiEpochReport`

*Line: 45*

### `UbiDistributor`

*Line: 57*

## Constants

| Name | Type | Value |
|------|------|-------|
| `UBI_EPOCH_BLOCKS` | auto | `u64 = 126_144` |
| `UBI_DAILY_SAT` | auto | `u64 = 1_000_000_000` |
| `UBI_PER_EPOCH_SAT` | auto | `u64 = UBI_DAILY_SAT * UBI_EPOCH_BLOCKS / 86_400` |
| `MAX_BENEFICIARIES` | auto | `usize = 1_000_000_000` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) UbiDistributor {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `UbiDistributor`

*Line: 73*

---

### `deinit`

```zig
pub fn deinit(self: *UbiDistributor) void {
```

**Parameters:**

- `self`: `*UbiDistributor`

*Line: 84*

---

### `addToPool`

Adauga profit din VaultEngine in pool

```zig
pub fn addToPool(self: *UbiDistributor, amount_sat: u64) void {
```

**Parameters:**

- `self`: `*UbiDistributor`
- `amount_sat`: `u64`

*Line: 112*

---

### `activeCount`

```zig
pub fn activeCount(self: *const UbiDistributor) u64 {
```

**Parameters:**

- `self`: `*const UbiDistributor`

**Returns:** `u64`

*Line: 168*

---

### `printStatus`

```zig
pub fn printStatus(self: *const UbiDistributor) void {
```

**Parameters:**

- `self`: `*const UbiDistributor`

*Line: 184*

---

