# Module: `block`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Block`

*Line: 12*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Transaction` | auto | `transaction_mod.Transaction` |
| `MAX_BLOCK_SIZE` | auto | `usize = 1_048_576` |
| `MAX_BLOCK_TX` | auto | `usize = 10_000` |

## Functions

### `calculateMerkleRoot`

Calculeaza Merkle Root din toate TX hashes (binary Merkle tree, ca Bitcoin)

```zig
pub fn calculateMerkleRoot(self: *const Block) [32]u8 {
```

**Parameters:**

- `self`: `*const Block`

**Returns:** `[32]u8`

*Line: 30*

---

### `calculateHash`

```zig
pub fn calculateHash(self: *const Block) ![32]u8 {
```

**Parameters:**

- `self`: `*const Block`

**Returns:** `![32]u8`

*Line: 58*

---

### `validateTransactions`

```zig
pub fn validateTransactions(self: *const Block) bool {
```

**Parameters:**

- `self`: `*const Block`

**Returns:** `bool`

*Line: 78*

---

### `getTransactionCount`

```zig
pub fn getTransactionCount(self: *const Block) u32 {
```

**Parameters:**

- `self`: `*const Block`

**Returns:** `u32`

*Line: 87*

---

### `addTransaction`

```zig
pub fn addTransaction(self: *Block, tx: Transaction) !void {
```

**Parameters:**

- `self`: `*Block`
- `tx`: `Transaction`

**Returns:** `!void`

*Line: 91*

---

