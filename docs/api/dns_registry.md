# Module: `dns_registry`

> Decentralized DNS — register human-readable names, renewal periods, on-chain resolution.

**Source:** `core/dns_registry.zig` | **Lines:** 265 | **Functions:** 9 | **Structs:** 2 | **Tests:** 10

---

## Contents

### Structs
- [`DnsEntry`](#dnsentry) — DNS entry
- [`DnsRegistry`](#dnsregistry) — DNS Registry Engine

### Constants
- [5 constants defined](#constants)

### Functions
- [`isValidName()`](#isvalidname) — Validate a name
- [`getName()`](#getname) — Returns the current name.
- [`getAddress()`](#getaddress) — Returns the current address.
- [`isExpired()`](#isexpired) — Checks whether the expired condition is true.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`resolve()`](#resolve) — Resolve name to address
- [`reverseResolve()`](#reverseresolve) — Reverse resolve: address to name
- [`renew()`](#renew) — Renew a name (extend expiry)
- [`activeCount()`](#activecount) — Count active (non-expired) entries

---

## Structs

### `DnsEntry`

DNS entry

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[MAX_NAME_LEN]u8` | Name |
| `name_len` | `u8` | Name_len |
| `address` | `[64]u8` | Address |
| `addr_len` | `u8` | Addr_len |
| `owner` | `[64]u8` | Owner |
| `owner_len` | `u8` | Owner_len |
| `registered_block` | `u64` | Registered_block |
| `expires_block` | `u64` | Expires_block |
| `active` | `bool` | Active |

*Defined at line 43*

---

### `DnsRegistry`

DNS Registry Engine

| Field | Type | Description |
|-------|------|-------------|
| `entries` | `[MAX_ENTRIES]DnsEntry` | Entries |
| `entry_count` | `usize` | Entry_count |
| `self` | `*DnsRegistry` | Self |
| `name` | `[]const u8` | Name |
| `address` | `[]const u8` | Address |
| `owner` | `[]const u8` | Owner |
| `current_block` | `u64` | Current_block |

*Defined at line 74*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MAX_NAME_LEN` | `usize = 25` | M a x_ n a m e_ l e n |
| `MIN_NAME_LEN` | `usize = 3` | M i n_ n a m e_ l e n |
| `MAX_ENTRIES` | `usize = 1024` | M a x_ e n t r i e s |
| `REGISTER_COST_SAT` | `u64 = 1_000_000_000` | R e g i s t e r_ c o s t_ s a t |
| `RENEWAL_PERIOD_BLOCKS` | `u64 = 31_557_600` | R e n e w a l_ p e r i o d_ b l o c k s |

---

## Functions

### `isValidName()`

Validate a name

```zig
pub fn isValidName(name: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `[]const u8` | Name |

**Returns:** `bool`

*Defined at line 32*

---

### `getName()`

Returns the current name.

```zig
pub fn getName(self: *const DnsEntry) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DnsEntry` | The instance |

**Returns:** `[]const u8`

*Defined at line 60*

---

### `getAddress()`

Returns the current address.

```zig
pub fn getAddress(self: *const DnsEntry) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DnsEntry` | The instance |

**Returns:** `[]const u8`

*Defined at line 64*

---

### `isExpired()`

Checks whether the expired condition is true.

```zig
pub fn isExpired(self: *const DnsEntry, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DnsEntry` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 68*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() DnsRegistry {
```

**Returns:** `DnsRegistry`

*Defined at line 78*

---

### `resolve()`

Resolve name to address

```zig
pub fn resolve(self: *const DnsRegistry, name: []const u8, current_block: u64) ?[]const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DnsRegistry` | The instance |
| `name` | `[]const u8` | Name |
| `current_block` | `u64` | Current_block |

**Returns:** `?[]const u8`

*Defined at line 121*

---

### `reverseResolve()`

Reverse resolve: address to name

```zig
pub fn reverseResolve(self: *const DnsRegistry, address: []const u8, current_block: u64) ?[]const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DnsRegistry` | The instance |
| `address` | `[]const u8` | Address |
| `current_block` | `u64` | Current_block |

**Returns:** `?[]const u8`

*Defined at line 133*

---

### `renew()`

Renew a name (extend expiry)

```zig
pub fn renew(self: *DnsRegistry, name: []const u8, owner: []const u8, current_block: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*DnsRegistry` | The instance |
| `name` | `[]const u8` | Name |
| `owner` | `[]const u8` | Owner |
| `current_block` | `u64` | Current_block |

**Returns:** `!void`

*Defined at line 145*

---

### `activeCount()`

Count active (non-expired) entries

```zig
pub fn activeCount(self: *const DnsRegistry, current_block: u64) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DnsRegistry` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `usize`

*Defined at line 175*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
