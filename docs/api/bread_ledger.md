# Module: `bread_ledger`

> Physical redemption system — BreadVoucher QR ledger, 1 OMNI = 1 bread worldwide, voucher tracking.

**Source:** `core/bread_ledger.zig` | **Lines:** 368 | **Functions:** 7 | **Structs:** 4 | **Tests:** 11

---

## Contents

### Structs
- [`BreadVoucher`](#breadvoucher) — Voucher de paine — emis cand user-ul initiaza redemption
- [`BreadMerchant`](#breadmerchant) — Merchant inregistrat — accepta voucher-e de paine
- [`BreadDelivery`](#breaddelivery) — Proof-of-Bread: dovada on-chain ca painea a fost livrata
- [`BreadLedger`](#breadledger) — Data structure for bread ledger. Fields include: allocator, vouchers, merchants,...

### Constants
- [3 constants defined](#constants)

### Functions
- [`isExpired()`](#isexpired) — Checks whether the expired condition is true.
- [`countryCode()`](#countrycode) — Returns the count of ry code.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`findVoucher()`](#findvoucher) — Searches for voucher matching the given criteria.
- [`pendingCount()`](#pendingcount) — Performs the pending count operation on the bread_ledger module.
- [`printStatus()`](#printstatus) — Performs the print status operation on the bread_ledger module.

---

## Structs

### `BreadVoucher`

Voucher de paine — emis cand user-ul initiaza redemption

| Field | Type | Description |
|-------|------|-------------|
| `voucher_id` | `u64` | Voucher_id |
| `owner` | `[32]u8` | Owner |
| `merchant` | `[32]u8` | Merchant |
| `amount_sat` | `u64` | Amount_sat |
| `bread_count` | `u64` | Bread_count |
| `issued_block` | `u64` | Issued_block |
| `redeemed_block` | `u64` | Redeemed_block |
| `status` | `BreadVoucherStatus` | Status |
| `qr_hash` | `[32]u8` | Qr_hash |

*Defined at line 33*

---

### `BreadMerchant`

Merchant inregistrat — accepta voucher-e de paine

| Field | Type | Description |
|-------|------|-------------|
| `merchant_addr` | `[32]u8` | Merchant_addr |
| `name` | `[64]u8` | Name |
| `name_len` | `u8` | Name_len |
| `country` | `[3]u8` | Country |
| `registered_block` | `u64` | Registered_block |
| `total_redeemed_sat` | `u64` | Total_redeemed_sat |
| `active` | `bool` | Active |

*Defined at line 52*

---

### `BreadDelivery`

Proof-of-Bread: dovada on-chain ca painea a fost livrata

| Field | Type | Description |
|-------|------|-------------|
| `voucher_id` | `u64` | Voucher_id |
| `merchant_addr` | `[32]u8` | Merchant_addr |
| `proof_hash` | `[32]u8` | Proof_hash |
| `delivery_block` | `u64` | Delivery_block |

*Defined at line 67*

---

### `BreadLedger`

Data structure for bread ledger. Fields include: allocator, vouchers, merchants, deliveries, next_voucher_id.

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `vouchers` | `std.array_list.Managed(BreadVoucher)` | Vouchers |
| `merchants` | `std.array_list.Managed(BreadMerchant)` | Merchants |
| `deliveries` | `std.array_list.Managed(BreadDelivery)` | Deliveries |
| `next_voucher_id` | `u64` | Next_voucher_id |
| `total_redeemed_sat` | `u64` | Total_redeemed_sat |
| `total_bread_issued` | `u64` | Total_bread_issued |
| `merchant_addr` | `[32]u8` | Merchant_addr |
| `name` | `[]const u8` | Name |
| `country` | `[3]u8` | Country |

*Defined at line 77*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `BREAD_PRICE_SAT` | `u64 = 1_000_000_000` | B r e a d_ p r i c e_ s a t |
| `VOUCHER_EXPIRY_BLOCKS` | `u64 = 30 * 86_400` | V o u c h e r_ e x p i r y_ b l o c k s |
| `BreadVoucherStatus` | `enum(u8) {` | Bread voucher status |

---

## Functions

### `isExpired()`

Checks whether the expired condition is true.

```zig
pub fn isExpired(self: *const BreadVoucher, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BreadVoucher` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 46*

---

### `countryCode()`

Returns the count of ry code.

```zig
pub fn countryCode(self: *const BreadMerchant) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BreadMerchant` | The instance |

**Returns:** `[]const u8`

*Defined at line 61*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) BreadLedger {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `BreadLedger`

*Defined at line 90*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *BreadLedger) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BreadLedger` | The instance |

*Defined at line 102*

---

### `findVoucher()`

Searches for voucher matching the given criteria.

```zig
pub fn findVoucher(self: *BreadLedger, voucher_id: u64) !*BreadVoucher {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BreadLedger` | The instance |
| `voucher_id` | `u64` | Voucher_id |

**Returns:** `!*BreadVoucher`

*Defined at line 228*

---

### `pendingCount()`

Performs the pending count operation on the bread_ledger module.

```zig
pub fn pendingCount(self: *const BreadLedger) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BreadLedger` | The instance |

**Returns:** `u64`

*Defined at line 235*

---

### `printStatus()`

Performs the print status operation on the bread_ledger module.

```zig
pub fn printStatus(self: *const BreadLedger) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BreadLedger` | The instance |

*Defined at line 243*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
