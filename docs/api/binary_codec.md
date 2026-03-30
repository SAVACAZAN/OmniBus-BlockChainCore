# Module: `binary_codec`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Varint`

Varint encoding - variable-length integers
Saves space: 255 needs 1 byte, not 4

*Line: 10*

### `BinaryEncoder`

Binary encoder for sub-blocks

*Line: 72*

### `BinaryDecoder`

Binary decoder for sub-blocks

*Line: 156*

## Constants

| Name | Type | Value |
|------|------|-------|
| `SubBlock` | auto | `sub_block_mod.SubBlock` |
| `Transaction` | auto | `transaction_mod.Transaction` |

## Functions

### `encodeU64`

Encode u64 as varint

```zig
pub fn encodeU64(value: u64) ![9]u8 {
```

**Parameters:**

- `value`: `u64`

**Returns:** `![9]u8`

*Line: 12*

---

### `decodeU64`

Decode varint back to u64

```zig
pub fn decodeU64(data: []const u8) ![2]usize {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `![2]usize`

*Line: 30*

---

### `encodeU32`

Encode u32 as varint

```zig
pub fn encodeU32(value: u32) ![5]u8 {
```

**Parameters:**

- `value`: `u32`

**Returns:** `![5]u8`

*Line: 47*

---

### `decodeU32`

Decode varint to u32

```zig
pub fn decodeU32(data: []const u8) ![2]usize {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `![2]usize`

*Line: 65*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) BinaryEncoder {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `BinaryEncoder`

*Line: 76*

---

### `encodeSubBlock`

```zig
pub fn encodeSubBlock(self: *BinaryEncoder, sub: *const SubBlock) !void {
```

**Parameters:**

- `self`: `*BinaryEncoder`
- `sub`: `*const SubBlock`

**Returns:** `!void`

*Line: 83*

---

### `encodeTransaction`

```zig
pub fn encodeTransaction(self: *BinaryEncoder, tx: *const Transaction) !void {
```

**Parameters:**

- `self`: `*BinaryEncoder`
- `tx`: `*const Transaction`

**Returns:** `!void`

*Line: 106*

---

### `encodeVarU32`

```zig
pub fn encodeVarU32(self: *BinaryEncoder, value: u32) !void {
```

**Parameters:**

- `self`: `*BinaryEncoder`
- `value`: `u32`

**Returns:** `!void`

*Line: 122*

---

### `encodeVarU64`

```zig
pub fn encodeVarU64(self: *BinaryEncoder, value: u64) !void {
```

**Parameters:**

- `self`: `*BinaryEncoder`
- `value`: `u64`

**Returns:** `!void`

*Line: 128*

---

### `getBytes`

```zig
pub fn getBytes(self: *const BinaryEncoder) []const u8 {
```

**Parameters:**

- `self`: `*const BinaryEncoder`

**Returns:** `[]const u8`

*Line: 142*

---

### `getSize`

```zig
pub fn getSize(self: *const BinaryEncoder) usize {
```

**Parameters:**

- `self`: `*const BinaryEncoder`

**Returns:** `usize`

*Line: 146*

---

### `deinit`

```zig
pub fn deinit(self: *BinaryEncoder) void {
```

**Parameters:**

- `self`: `*BinaryEncoder`

*Line: 150*

---

### `init`

```zig
pub fn init(data: []const u8) BinaryDecoder {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `BinaryDecoder`

*Line: 160*

---

### `readU8`

```zig
pub fn readU8(self: *BinaryDecoder) !u8 {
```

**Parameters:**

- `self`: `*BinaryDecoder`

**Returns:** `!u8`

*Line: 167*

---

### `readBytes`

```zig
pub fn readBytes(self: *BinaryDecoder, comptime len: usize) ![len]u8 {
```

**Parameters:**

- `self`: `*BinaryDecoder`
- `comptime len`: `usize`

**Returns:** `![len]u8`

*Line: 174*

---

### `readVarU32`

```zig
pub fn readVarU32(self: *BinaryDecoder) !u32 {
```

**Parameters:**

- `self`: `*BinaryDecoder`

**Returns:** `!u32`

*Line: 182*

---

### `readVarU64`

```zig
pub fn readVarU64(self: *BinaryDecoder) !u64 {
```

**Parameters:**

- `self`: `*BinaryDecoder`

**Returns:** `!u64`

*Line: 188*

---

### `isEndOfData`

```zig
pub fn isEndOfData(self: *const BinaryDecoder) bool {
```

**Parameters:**

- `self`: `*const BinaryDecoder`

**Returns:** `bool`

*Line: 194*

---

