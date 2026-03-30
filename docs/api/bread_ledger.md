# Module: `bread_ledger`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `BreadVoucher`

Voucher de paine — emis cand user-ul initiaza redemption

*Line: 33*

### `BreadMerchant`

Merchant inregistrat — accepta voucher-e de paine

*Line: 52*

### `BreadDelivery`

Proof-of-Bread: dovada on-chain ca painea a fost livrata

*Line: 67*

### `BreadLedger`

*Line: 77*

## Constants

| Name | Type | Value |
|------|------|-------|
| `BREAD_PRICE_SAT` | auto | `u64 = 1_000_000_000` |
| `VOUCHER_EXPIRY_BLOCKS` | auto | `u64 = 30 * 86_400` |
| `BreadVoucherStatus` | auto | `enum(u8) {` |

## Functions

### `isExpired`

```zig
pub fn isExpired(self: *const BreadVoucher, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const BreadVoucher`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 46*

---

### `countryCode`

```zig
pub fn countryCode(self: *const BreadMerchant) []const u8 {
```

**Parameters:**

- `self`: `*const BreadMerchant`

**Returns:** `[]const u8`

*Line: 61*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) BreadLedger {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `BreadLedger`

*Line: 90*

---

### `deinit`

```zig
pub fn deinit(self: *BreadLedger) void {
```

**Parameters:**

- `self`: `*BreadLedger`

*Line: 102*

---

### `findVoucher`

```zig
pub fn findVoucher(self: *BreadLedger, voucher_id: u64) !*BreadVoucher {
```

**Parameters:**

- `self`: `*BreadLedger`
- `voucher_id`: `u64`

**Returns:** `!*BreadVoucher`

*Line: 228*

---

### `pendingCount`

```zig
pub fn pendingCount(self: *const BreadLedger) u64 {
```

**Parameters:**

- `self`: `*const BreadLedger`

**Returns:** `u64`

*Line: 235*

---

### `printStatus`

```zig
pub fn printStatus(self: *const BreadLedger) void {
```

**Parameters:**

- `self`: `*const BreadLedger`

*Line: 243*

---

