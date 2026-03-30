# Module: `sub_block`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `SubBlock`

Sub-block — confirmare soft la 0.1s

*Line: 18*

### `KeyBlock`

*Line: 107*

### `SubBlockEngine`

*Line: 223*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Transaction` | auto | `transaction_mod.Transaction` |
| `Block` | auto | `blockchain_mod.Block` |
| `SUB_BLOCKS_PER_BLOCK` | auto | `u8 = 10` |
| `SUB_BLOCK_INTERVAL_MS` | auto | `u64 = 100` |
| `KeyBlockState` | auto | `enum {` |

## Functions

### `deinit`

```zig
pub fn deinit(self: *SubBlock) void {
```

**Parameters:**

- `self`: `*SubBlock`

*Line: 51*

---

### `addTransaction`

```zig
pub fn addTransaction(self: *SubBlock, tx: Transaction) !void {
```

**Parameters:**

- `self`: `*SubBlock`
- `tx`: `Transaction`

**Returns:** `!void`

*Line: 55*

---

### `finalize`

```zig
pub fn finalize(self: *SubBlock) void {
```

**Parameters:**

- `self`: `*SubBlock`

*Line: 60*

---

### `isValid`

```zig
pub fn isValid(self: *const SubBlock) bool {
```

**Parameters:**

- `self`: `*const SubBlock`

**Returns:** `bool`

*Line: 89*

---

### `init`

```zig
pub fn init(block_number: u32) KeyBlock {
```

**Parameters:**

- `block_number`: `u32`

**Returns:** `KeyBlock`

*Line: 121*

---

### `addSubBlock`

Adauga un sub-bloc (trebuie sa aiba sub_id unic 0-9)
Returneaza true daca Key-Block-ul e complet (10/10)

```zig
pub fn addSubBlock(self: *KeyBlock, sb: SubBlock) !bool {
```

**Parameters:**

- `self`: `*KeyBlock`
- `sb`: `SubBlock`

**Returns:** `!bool`

*Line: 137*

---

### `finalize`

Finalizeaza Key-Block-ul — calculeaza hash-ul agregat

```zig
pub fn finalize(self: *KeyBlock, reward_sat: u64) void {
```

**Parameters:**

- `self`: `*KeyBlock`
- `reward_sat`: `u64`

*Line: 154*

---

### `totalTxCount`

Total TX-uri din toate sub-blocurile

```zig
pub fn totalTxCount(self: *const KeyBlock) u32 {
```

**Parameters:**

- `self`: `*const KeyBlock`

**Returns:** `u32`

*Line: 163*

---

### `latencyMs`

Latenta totala de la primul sub-bloc la finalizare (ms)

```zig
pub fn latencyMs(self: *const KeyBlock) i64 {
```

**Parameters:**

- `self`: `*const KeyBlock`

**Returns:** `i64`

*Line: 172*

---

### `missing`

Cate sub-blocuri lipsesc

```zig
pub fn missing(self: *const KeyBlock) u8 {
```

**Parameters:**

- `self`: `*const KeyBlock`

**Returns:** `u8`

*Line: 178*

---

### `printStatus`

```zig
pub fn printStatus(self: *const KeyBlock) void {
```

**Parameters:**

- `self`: `*const KeyBlock`

*Line: 209*

---

