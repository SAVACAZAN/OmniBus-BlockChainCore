# Module: `dns_registry`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `DnsEntry`

DNS entry

*Line: 43*

### `DnsRegistry`

DNS Registry Engine

*Line: 74*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MAX_NAME_LEN` | auto | `usize = 25` |
| `MIN_NAME_LEN` | auto | `usize = 3` |
| `MAX_ENTRIES` | auto | `usize = 1024` |
| `REGISTER_COST_SAT` | auto | `u64 = 1_000_000_000` |
| `RENEWAL_PERIOD_BLOCKS` | auto | `u64 = 31_557_600` |

## Functions

### `isValidName`

Validate a name

```zig
pub fn isValidName(name: []const u8) bool {
```

**Parameters:**

- `name`: `[]const u8`

**Returns:** `bool`

*Line: 32*

---

### `getName`

```zig
pub fn getName(self: *const DnsEntry) []const u8 {
```

**Parameters:**

- `self`: `*const DnsEntry`

**Returns:** `[]const u8`

*Line: 60*

---

### `getAddress`

```zig
pub fn getAddress(self: *const DnsEntry) []const u8 {
```

**Parameters:**

- `self`: `*const DnsEntry`

**Returns:** `[]const u8`

*Line: 64*

---

### `isExpired`

```zig
pub fn isExpired(self: *const DnsEntry, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const DnsEntry`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 68*

---

### `init`

```zig
pub fn init() DnsRegistry {
```

**Returns:** `DnsRegistry`

*Line: 78*

---

### `resolve`

Resolve name to address

```zig
pub fn resolve(self: *const DnsRegistry, name: []const u8, current_block: u64) ?[]const u8 {
```

**Parameters:**

- `self`: `*const DnsRegistry`
- `name`: `[]const u8`
- `current_block`: `u64`

**Returns:** `?[]const u8`

*Line: 121*

---

### `reverseResolve`

Reverse resolve: address to name

```zig
pub fn reverseResolve(self: *const DnsRegistry, address: []const u8, current_block: u64) ?[]const u8 {
```

**Parameters:**

- `self`: `*const DnsRegistry`
- `address`: `[]const u8`
- `current_block`: `u64`

**Returns:** `?[]const u8`

*Line: 133*

---

### `renew`

Renew a name (extend expiry)

```zig
pub fn renew(self: *DnsRegistry, name: []const u8, owner: []const u8, current_block: u64) !void {
```

**Parameters:**

- `self`: `*DnsRegistry`
- `name`: `[]const u8`
- `owner`: `[]const u8`
- `current_block`: `u64`

**Returns:** `!void`

*Line: 145*

---

### `activeCount`

Count active (non-expired) entries

```zig
pub fn activeCount(self: *const DnsRegistry, current_block: u64) usize {
```

**Parameters:**

- `self`: `*const DnsRegistry`
- `current_block`: `u64`

**Returns:** `usize`

*Line: 175*

---

