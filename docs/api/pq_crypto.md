# Module: `pq_crypto`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `MlDsa87`

*Line: 78*

### `Falcon512`

*Line: 152*

### `SlhDsa256s`

*Line: 234*

### `MlKem768`

*Line: 324*

### `PQCrypto`

*Line: 528*

## Constants

| Name | Type | Value |
|------|------|-------|
| `PUBLIC_KEY_SIZE` | auto | `usize = 2592` |
| `SECRET_KEY_SIZE` | auto | `usize = 4896` |
| `SIGNATURE_MAX` | auto | `usize = 4627` |
| `PUBLIC_KEY_SIZE` | auto | `usize = 897` |
| `SECRET_KEY_SIZE` | auto | `usize = 1281` |
| `SIGNATURE_MAX` | auto | `usize = 752` |
| `PUBLIC_KEY_SIZE` | auto | `usize = 64` |
| `SECRET_KEY_SIZE` | auto | `usize = 128` |
| `SIGNATURE_MAX` | auto | `usize = 29792` |
| `PUBLIC_KEY_SIZE` | auto | `usize = 1184` |
| `SECRET_KEY_SIZE` | auto | `usize = 2400` |
| `CIPHERTEXT_SIZE` | auto | `usize = 1088` |
| `SHARED_SECRET_SIZE` | auto | `usize = 32` |
| `Dilithium5` | auto | `MlDsa87` |
| `SPHINCSPlus` | auto | `SlhDsa256s` |
| `Kyber768` | auto | `MlKem768` |
| `DomainAlgorithm` | auto | `enum { MlDsa87, Falcon512, SlhDsa256s }` |

## Functions

### `generateKeyPair`

```zig
pub fn generateKeyPair() !MlDsa87 {
```

**Returns:** `!MlDsa87`

*Line: 86*

---

### `sign`

```zig
pub fn sign(self: *const MlDsa87, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const MlDsa87`
- `message`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 106*

---

### `verify`

```zig
pub fn verify(self: *const MlDsa87, message: []const u8, signature: []const u8) bool {
```

**Parameters:**

- `self`: `*const MlDsa87`
- `message`: `[]const u8`
- `signature`: `[]const u8`

**Returns:** `bool`

*Line: 130*

---

### `generateKeyPair`

```zig
pub fn generateKeyPair() !Falcon512 {
```

**Returns:** `!Falcon512`

*Line: 160*

---

### `sign`

```zig
pub fn sign(self: *const Falcon512, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const Falcon512`
- `message`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 177*

---

### `verify`

```zig
pub fn verify(self: *const Falcon512, message: []const u8, signature: []const u8) bool {
```

**Parameters:**

- `self`: `*const Falcon512`
- `message`: `[]const u8`
- `signature`: `[]const u8`

**Returns:** `bool`

*Line: 207*

---

### `generateKeyPair`

```zig
pub fn generateKeyPair() !SlhDsa256s {
```

**Returns:** `!SlhDsa256s`

*Line: 242*

---

### `sign`

```zig
pub fn sign(self: *const SlhDsa256s, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const SlhDsa256s`
- `message`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 267*

---

### `verify`

```zig
pub fn verify(self: *const SlhDsa256s, message: []const u8, signature: []const u8) bool {
```

**Parameters:**

- `self`: `*const SlhDsa256s`
- `message`: `[]const u8`
- `signature`: `[]const u8`

**Returns:** `bool`

*Line: 292*

---

### `generateKeyPair`

```zig
pub fn generateKeyPair() !MlKem768 {
```

**Returns:** `!MlKem768`

*Line: 333*

---

### `encapsulate`

```zig
pub fn encapsulate(self: *const MlKem768, allocator: std.mem.Allocator) !struct {
```

**Parameters:**

- `self`: `*const MlKem768`
- `allocator`: `std.mem.Allocator`

**Returns:** `!struct`

*Line: 378*

---

### `decapsulate`

```zig
pub fn decapsulate(self: *const MlKem768, ciphertext: []const u8) ![SHARED_SECRET_SIZE]u8 {
```

**Parameters:**

- `self`: `*const MlKem768`
- `ciphertext`: `[]const u8`

**Returns:** `![SHARED_SECRET_SIZE]u8`

*Line: 439*

---

### `algorithmForCoinType`

```zig
pub fn algorithmForCoinType(coin_type: u32) ?DomainAlgorithm {
```

**Parameters:**

- `coin_type`: `u32`

**Returns:** `?DomainAlgorithm`

*Line: 536*

---

