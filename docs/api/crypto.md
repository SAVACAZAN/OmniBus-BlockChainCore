# Module: `crypto`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `Crypto`

Cryptographic primitives for OmniBus blockchain

*Line: 4*

## Functions

### `sha256`

SHA-256 hash

```zig
pub fn sha256(data: []const u8) [32]u8 {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `[32]u8`

*Line: 6*

---

### `sha256d`

SHA-256 double hash (Bitcoin style)

```zig
pub fn sha256d(data: []const u8) [32]u8 {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `[32]u8`

*Line: 15*

---

### `hmacSha256`

HMAC-SHA256

```zig
pub fn hmacSha256(key: []const u8, message: []const u8) [32]u8 {
```

**Parameters:**

- `key`: `[]const u8`
- `message`: `[]const u8`

**Returns:** `[32]u8`

*Line: 25*

---

### `hmacSha512`

HMAC-SHA512 (BIP32 standard)

```zig
pub fn hmacSha512(key: []const u8, message: []const u8) [64]u8 {
```

**Parameters:**

- `key`: `[]const u8`
- `message`: `[]const u8`

**Returns:** `[64]u8`

*Line: 33*

---

### `ripemd160`

RIPEMD-160 (for Bitcoin addresses)
Simplified - returns first 20 bytes of SHA256 for now

```zig
pub fn ripemd160(data: []const u8) [20]u8 {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `[20]u8`

*Line: 42*

---

### `bytesToHex`

Convert bytes to hex string

```zig
pub fn bytesToHex(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `bytes`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 50*

---

### `hexToBytes`

Convert hex string to bytes

```zig
pub fn hexToBytes(hex: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `hex`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 63*

---

### `randomBytes`

Random number generation

```zig
pub fn randomBytes(buffer: []u8) !void {
```

**Parameters:**

- `buffer`: `[]u8`

**Returns:** `!void`

*Line: 78*

---

### `encryptAES256`

AES-256-GCM encryption — real AEAD, nu XOR
Output: [nonce:12][tag:16][ciphertext:plaintext.len] — max plaintext 32 bytes
Returneaza buffer de 12+16+32 = 60 bytes (plaintext padding 0 la 32 daca mai scurt)

```zig
pub fn encryptAES256(plaintext: []const u8, key: [32]u8) ![60]u8 {
```

**Parameters:**

- `plaintext`: `[]const u8`
- `key`: `[32]u8`

**Returns:** `![60]u8`

*Line: 85*

---

### `decryptAES256`

AES-256-GCM decryption — returneaza [32]u8 plaintext sau error.AuthenticationFailed

```zig
pub fn decryptAES256(ciphertext: [60]u8, key: [32]u8) ![32]u8 {
```

**Parameters:**

- `ciphertext`: `[60]u8`
- `key`: `[32]u8`

**Returns:** `![32]u8`

*Line: 110*

---

### `isStrongPassword`

Verify password strength

```zig
pub fn isStrongPassword(password: []const u8) bool {
```

**Parameters:**

- `password`: `[]const u8`

**Returns:** `bool`

*Line: 125*

---

