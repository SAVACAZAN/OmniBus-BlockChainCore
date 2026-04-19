# Module: `binary_codec`

> Binary serialization — varint encoding, 93% compression ratio, block/TX serialization for network and storage.

**Source:** `core/binary_codec.zig` | **Lines:** 258 | **Functions:** 18 | **Structs:** 3 | **Tests:** 5

---

## Contents

### Structs
- [`Varint`](#varint) — Varint encoding - variable-length integers
Saves space: 255 needs 1 byte, not 4
- [`BinaryEncoder`](#binaryencoder) — Binary encoder for sub-blocks
- [`BinaryDecoder`](#binarydecoder) — Binary decoder for sub-blocks

### Constants
- [2 constants defined](#constants)

### Functions
- [`encodeU64()`](#encodeu64) — Encode u64 as varint
- [`decodeU64()`](#decodeu64) — Decode varint back to u64
- [`encodeU32()`](#encodeu32) — Encode u32 as varint
- [`decodeU32()`](#decodeu32) — Decode varint to u32
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`encodeSubBlock()`](#encodesubblock) — Decodes the encoded data back to its original format.
- [`encodeTransaction()`](#encodetransaction) — Decodes the encoded data back to its original format.
- [`encodeVarU32()`](#encodevaru32) — Decodes the encoded data back to its original format.
- [`encodeVarU64()`](#encodevaru64) — Decodes the encoded data back to its original format.
- [`getBytes()`](#getbytes) — Returns the current bytes.
- [`getSize()`](#getsize) — Returns the current size.
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`readU8()`](#readu8) — Performs the read u8 operation on the binary_codec module.
- [`readBytes()`](#readbytes) — Performs the read bytes operation on the binary_codec module.
- [`readVarU32()`](#readvaru32) — Performs the read var u32 operation on the binary_codec module.
- [`readVarU64()`](#readvaru64) — Performs the read var u64 operation on the binary_codec module.
- [`isEndOfData()`](#isendofdata) — Checks whether the end of data condition is true.

---

## Structs

### `Varint`

Varint encoding - variable-length integers
Saves space: 255 needs 1 byte, not 4

*Defined at line 10*

---

### `BinaryEncoder`

Binary encoder for sub-blocks

| Field | Type | Description |
|-------|------|-------------|
| `buffer` | `std.array_list.Managed(u8)` | Buffer |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 72*

---

### `BinaryDecoder`

Binary decoder for sub-blocks

| Field | Type | Description |
|-------|------|-------------|
| `data` | `[]const u8` | Data |
| `offset` | `usize` | Offset |

*Defined at line 156*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `SubBlock` | `sub_block_mod.SubBlock` | Sub block |
| `Transaction` | `transaction_mod.Transaction` | Transaction |

---

## Functions

### `encodeU64()`

Encode u64 as varint

```zig
pub fn encodeU64(value: u64) ![9]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `u64` | Value |

**Returns:** `![9]u8`

*Defined at line 12*

---

### `decodeU64()`

Decode varint back to u64

```zig
pub fn decodeU64(data: []const u8) ![2]usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `![2]usize`

*Defined at line 30*

---

### `encodeU32()`

Encode u32 as varint

```zig
pub fn encodeU32(value: u32) ![5]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `u32` | Value |

**Returns:** `![5]u8`

*Defined at line 47*

---

### `decodeU32()`

Decode varint to u32

```zig
pub fn decodeU32(data: []const u8) ![2]usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `![2]usize`

*Defined at line 65*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) BinaryEncoder {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `BinaryEncoder`

*Defined at line 76*

---

### `encodeSubBlock()`

Decodes the encoded data back to its original format.

```zig
pub fn encodeSubBlock(self: *BinaryEncoder, sub: *const SubBlock) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryEncoder` | The instance |
| `sub` | `*const SubBlock` | Sub |

**Returns:** `!void`

*Defined at line 83*

---

### `encodeTransaction()`

Decodes the encoded data back to its original format.

```zig
pub fn encodeTransaction(self: *BinaryEncoder, tx: *const Transaction) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryEncoder` | The instance |
| `tx` | `*const Transaction` | Tx |

**Returns:** `!void`

*Defined at line 106*

---

### `encodeVarU32()`

Decodes the encoded data back to its original format.

```zig
pub fn encodeVarU32(self: *BinaryEncoder, value: u32) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryEncoder` | The instance |
| `value` | `u32` | Value |

**Returns:** `!void`

*Defined at line 122*

---

### `encodeVarU64()`

Decodes the encoded data back to its original format.

```zig
pub fn encodeVarU64(self: *BinaryEncoder, value: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryEncoder` | The instance |
| `value` | `u64` | Value |

**Returns:** `!void`

*Defined at line 128*

---

### `getBytes()`

Returns the current bytes.

```zig
pub fn getBytes(self: *const BinaryEncoder) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BinaryEncoder` | The instance |

**Returns:** `[]const u8`

*Defined at line 142*

---

### `getSize()`

Returns the current size.

```zig
pub fn getSize(self: *const BinaryEncoder) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BinaryEncoder` | The instance |

**Returns:** `usize`

*Defined at line 146*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *BinaryEncoder) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryEncoder` | The instance |

*Defined at line 150*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(data: []const u8) BinaryDecoder {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `BinaryDecoder`

*Defined at line 160*

---

### `readU8()`

Performs the read u8 operation on the binary_codec module.

```zig
pub fn readU8(self: *BinaryDecoder) !u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryDecoder` | The instance |

**Returns:** `!u8`

*Defined at line 167*

---

### `readBytes()`

Performs the read bytes operation on the binary_codec module.

```zig
pub fn readBytes(self: *BinaryDecoder, comptime len: usize) ![len]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryDecoder` | The instance |
| `comptime len` | `usize` | Comptime len |

**Returns:** `![len]u8`

*Defined at line 174*

---

### `readVarU32()`

Performs the read var u32 operation on the binary_codec module.

```zig
pub fn readVarU32(self: *BinaryDecoder) !u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryDecoder` | The instance |

**Returns:** `!u32`

*Defined at line 182*

---

### `readVarU64()`

Performs the read var u64 operation on the binary_codec module.

```zig
pub fn readVarU64(self: *BinaryDecoder) !u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BinaryDecoder` | The instance |

**Returns:** `!u64`

*Defined at line 188*

---

### `isEndOfData()`

Checks whether the end of data condition is true.

```zig
pub fn isEndOfData(self: *const BinaryDecoder) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BinaryDecoder` | The instance |

**Returns:** `bool`

*Defined at line 194*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
