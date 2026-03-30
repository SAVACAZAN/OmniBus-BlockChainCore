# Module: `compact_transaction`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `CompactTransaction`

SegWit-style compact transaction (signatures separated)
Reduces per-transaction size by 60%

*Line: 8*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Transaction` | auto | `transaction_mod.Transaction` |

## Functions

### `init`

```zig
pub fn init() CompactTransaction {
```

**Returns:** `CompactTransaction`

*Line: 26*

---

### `fromTransaction`

Convert from full Transaction to CompactTransaction

```zig
pub fn fromTransaction(tx: *const Transaction) CompactTransaction {
```

**Parameters:**

- `tx`: `*const Transaction`

**Returns:** `CompactTransaction`

*Line: 41*

---

### `serialize`

Serialize to binary format (161 bytes)

```zig
pub fn serialize(self: *const CompactTransaction, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const CompactTransaction`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 77*

---

### `deserialize`

Deserialize from binary

```zig
pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !CompactTransaction {
```

**Parameters:**

- `data`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!CompactTransaction`

*Line: 122*

---

### `print`

```zig
pub fn print(self: *const CompactTransaction) void {
```

**Parameters:**

- `self`: `*const CompactTransaction`

*Line: 169*

---

