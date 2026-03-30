# Module: `pq_crypto`

> Post-Quantum cryptography via liboqs C bindings — ML-DSA-87 (Dilithium-5), Falcon-512, SLH-DSA-256s (SPHINCS+), ML-KEM-768 (Kyber) key generation, signing, verification.

**Source:** `core/pq_crypto.zig` | **Lines:** 668 | **Functions:** 13 | **Structs:** 5 | **Tests:** 13

---

## Contents

### Structs
- [`MlDsa87`](#mldsa87) — Data structure for ml dsa87. Fields include: secret_key.
- [`Falcon512`](#falcon512) — Data structure for falcon512. Fields include: secret_key.
- [`SlhDsa256s`](#slhdsa256s) — Data structure for slh dsa256s. Fields include: secret_key.
- [`MlKem768`](#mlkem768) — Data structure for ml kem768. Fields include: secret_key.
- [`PQCrypto`](#pqcrypto) — Data structure representing a p q crypto in the pq_crypto module.

### Constants
- [17 constants defined](#constants)

### Functions
- [`generateKeyPair()`](#generatekeypair) — Performs the generate key pair operation on the pq_crypto module.
- [`sign()`](#sign) — Cryptographically signs the data using the private key.
- [`verify()`](#verify) — Validates the pq_crypto. Returns true if valid, false otherwise.
- [`generateKeyPair()`](#generatekeypair) — Performs the generate key pair operation on the pq_crypto module.
- [`sign()`](#sign) — Cryptographically signs the data using the private key.
- [`verify()`](#verify) — Validates the pq_crypto. Returns true if valid, false otherwise.
- [`generateKeyPair()`](#generatekeypair) — Performs the generate key pair operation on the pq_crypto module.
- [`sign()`](#sign) — Cryptographically signs the data using the private key.
- [`verify()`](#verify) — Validates the pq_crypto. Returns true if valid, false otherwise.
- [`generateKeyPair()`](#generatekeypair) — Performs the generate key pair operation on the pq_crypto module.
- [`encapsulate()`](#encapsulate) — Performs the encapsulate operation on the pq_crypto module.
- [`decapsulate()`](#decapsulate) — Performs the decapsulate operation on the pq_crypto module.
- [`algorithmForCoinType()`](#algorithmforcointype) — Performs the algorithm for coin type operation on the pq_crypto module...

---

## Structs

### `MlDsa87`

Data structure for ml dsa87. Fields include: secret_key.

| Field | Type | Description |
|-------|------|-------------|
| `secret_key` | `[SECRET_KEY_SIZE]u8` | Secret_key |

*Defined at line 78*

---

### `Falcon512`

Data structure for falcon512. Fields include: secret_key.

| Field | Type | Description |
|-------|------|-------------|
| `secret_key` | `[SECRET_KEY_SIZE]u8` | Secret_key |

*Defined at line 152*

---

### `SlhDsa256s`

Data structure for slh dsa256s. Fields include: secret_key.

| Field | Type | Description |
|-------|------|-------------|
| `secret_key` | `[SECRET_KEY_SIZE]u8` | Secret_key |

*Defined at line 234*

---

### `MlKem768`

Data structure for ml kem768. Fields include: secret_key.

| Field | Type | Description |
|-------|------|-------------|
| `secret_key` | `[SECRET_KEY_SIZE]u8` | Secret_key |

*Defined at line 324*

---

### `PQCrypto`

Data structure representing a p q crypto in the pq_crypto module.

*Defined at line 528*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `PUBLIC_KEY_SIZE` | `usize = 2592` | P u b l i c_ k e y_ s i z e |
| `SECRET_KEY_SIZE` | `usize = 4896` | S e c r e t_ k e y_ s i z e |
| `SIGNATURE_MAX` | `usize = 4627` | S i g n a t u r e_ m a x |
| `PUBLIC_KEY_SIZE` | `usize = 897` | P u b l i c_ k e y_ s i z e |
| `SECRET_KEY_SIZE` | `usize = 1281` | S e c r e t_ k e y_ s i z e |
| `SIGNATURE_MAX` | `usize = 752` | S i g n a t u r e_ m a x |
| `PUBLIC_KEY_SIZE` | `usize = 64` | P u b l i c_ k e y_ s i z e |
| `SECRET_KEY_SIZE` | `usize = 128` | S e c r e t_ k e y_ s i z e |
| `SIGNATURE_MAX` | `usize = 29792` | S i g n a t u r e_ m a x |
| `PUBLIC_KEY_SIZE` | `usize = 1184` | P u b l i c_ k e y_ s i z e |
| `SECRET_KEY_SIZE` | `usize = 2400` | S e c r e t_ k e y_ s i z e |
| `CIPHERTEXT_SIZE` | `usize = 1088` | C i p h e r t e x t_ s i z e |
| `SHARED_SECRET_SIZE` | `usize = 32` | S h a r e d_ s e c r e t_ s i z e |
| `Dilithium5` | `MlDsa87` | Dilithium5 |
| `SPHINCSPlus` | `SlhDsa256s` | S p h i n c s plus |
| `Kyber768` | `MlKem768` | Kyber768 |
| `DomainAlgorithm` | `enum { MlDsa87, Falcon512, SlhDsa256s }` | Domain algorithm |

---

## Functions

### `generateKeyPair()`

Performs the generate key pair operation on the pq_crypto module.

```zig
pub fn generateKeyPair() !MlDsa87 {
```

**Returns:** `!MlDsa87`

*Defined at line 86*

---

### `sign()`

Cryptographically signs the data using the private key.

```zig
pub fn sign(self: *const MlDsa87, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MlDsa87` | The instance |
| `message` | `[]const u8` | Message |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 106*

---

### `verify()`

Validates the pq_crypto. Returns true if valid, false otherwise.

```zig
pub fn verify(self: *const MlDsa87, message: []const u8, signature: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MlDsa87` | The instance |
| `message` | `[]const u8` | Message |
| `signature` | `[]const u8` | Signature |

**Returns:** `bool`

*Defined at line 130*

---

### `generateKeyPair()`

Performs the generate key pair operation on the pq_crypto module.

```zig
pub fn generateKeyPair() !Falcon512 {
```

**Returns:** `!Falcon512`

*Defined at line 160*

---

### `sign()`

Cryptographically signs the data using the private key.

```zig
pub fn sign(self: *const Falcon512, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Falcon512` | The instance |
| `message` | `[]const u8` | Message |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 177*

---

### `verify()`

Validates the pq_crypto. Returns true if valid, false otherwise.

```zig
pub fn verify(self: *const Falcon512, message: []const u8, signature: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Falcon512` | The instance |
| `message` | `[]const u8` | Message |
| `signature` | `[]const u8` | Signature |

**Returns:** `bool`

*Defined at line 207*

---

### `generateKeyPair()`

Performs the generate key pair operation on the pq_crypto module.

```zig
pub fn generateKeyPair() !SlhDsa256s {
```

**Returns:** `!SlhDsa256s`

*Defined at line 242*

---

### `sign()`

Cryptographically signs the data using the private key.

```zig
pub fn sign(self: *const SlhDsa256s, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SlhDsa256s` | The instance |
| `message` | `[]const u8` | Message |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 267*

---

### `verify()`

Validates the pq_crypto. Returns true if valid, false otherwise.

```zig
pub fn verify(self: *const SlhDsa256s, message: []const u8, signature: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SlhDsa256s` | The instance |
| `message` | `[]const u8` | Message |
| `signature` | `[]const u8` | Signature |

**Returns:** `bool`

*Defined at line 292*

---

### `generateKeyPair()`

Performs the generate key pair operation on the pq_crypto module.

```zig
pub fn generateKeyPair() !MlKem768 {
```

**Returns:** `!MlKem768`

*Defined at line 333*

---

### `encapsulate()`

Performs the encapsulate operation on the pq_crypto module.

```zig
pub fn encapsulate(self: *const MlKem768, allocator: std.mem.Allocator) !struct {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MlKem768` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!struct`

*Defined at line 378*

---

### `decapsulate()`

Performs the decapsulate operation on the pq_crypto module.

```zig
pub fn decapsulate(self: *const MlKem768, ciphertext: []const u8) ![SHARED_SECRET_SIZE]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MlKem768` | The instance |
| `ciphertext` | `[]const u8` | Ciphertext |

**Returns:** `![SHARED_SECRET_SIZE]u8`

*Defined at line 439*

---

### `algorithmForCoinType()`

Performs the algorithm for coin type operation on the pq_crypto module.

```zig
pub fn algorithmForCoinType(coin_type: u32) ?DomainAlgorithm {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `coin_type` | `u32` | Coin_type |

**Returns:** `?DomainAlgorithm`

*Defined at line 536*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
