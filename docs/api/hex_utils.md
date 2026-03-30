# Module: `hex_utils`

## Contents

- [Functions](#functions)

## Functions

### `charToNibble`

Shared hex/hash utilities used by transaction.zig, blockchain.zig, blockchain_v2.zig
Extracted to eliminate code duplication (was duplicated in 3 files)
Convert hex character to 4-bit nibble value

```zig
pub fn charToNibble(c: u8) !u8 {
```

**Parameters:**

- `c`: `u8`

**Returns:** `!u8`

*Line: 7*

---

### `hexToBytes`

Convert hex string to bytes

```zig
pub fn hexToBytes(hex: []const u8, out: []u8) !void {
```

**Parameters:**

- `hex`: `[]const u8`
- `out`: `[]u8`

**Returns:** `!void`

*Line: 17*

---

### `isValidHashDifficulty`

Check if a hex hash meets difficulty (leading zeros count)

```zig
pub fn isValidHashDifficulty(hash: []const u8, difficulty: u32) bool {
```

**Parameters:**

- `hash`: `[]const u8`
- `difficulty`: `u32`

**Returns:** `bool`

*Line: 60*

---

