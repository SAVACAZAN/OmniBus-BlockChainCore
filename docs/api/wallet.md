# Module: `wallet`

> HD Wallet with Post-Quantum support — derives keys from BIP-39 mnemonic via BIP-32 (HMAC-SHA512), generates 5 PQ address domains (ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768), and creates signed transactions.

**Source:** `core/wallet.zig` | **Lines:** 473 | **Functions:** 10 | **Structs:** 3 | **Tests:** 5

---

## Contents

### Structs
- [`Wallet`](#wallet) — OmniBus Wallet — derivare reala BIP32 + secp256k1
- [`Address`](#address) — A blockchain address — includes the algorithm type, public key, and formatted ad...
- [`PQSignResult`](#pqsignresult) — Rezultatul semnarii pentru un domeniu PQ

### Functions
- [`fromMnemonic()`](#frommnemonic) — Creeaza wallet din mnemonic (BIP-39) si passphrase
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`getBalance()`](#getbalance) — Returns the current balance.
- [`getBalanceOMNI()`](#getbalanceomni) — Returns the current balance o m n i.
- [`canSend()`](#cansend) — Verifica daca ai suficienta balanta pentru un transfer
- [`updateBalance()`](#updatebalance) — Actualizeaza balanta (apelat din RPC fetch)
- [`getAddress()`](#getaddress) — Returns the address for the given index.
- [`getAllAddresses()`](#getalladdresses) — Returns the current all addresses.
- [`pubkeyHash160()`](#pubkeyhash160) — Compute Hash160(pubkey) = RIPEMD160(SHA256(pubkey))
Used for P2PKH scr...
- [`printAddresses()`](#printaddresses) — Performs the print addresses operation on the wallet module.

---

## Structs

### `Wallet`

OmniBus Wallet — derivare reala BIP32 + secp256k1

| Field | Type | Description |
|-------|------|-------------|
| `address` | `[]u8` | Address |
| `balance` | `u64` | Balance |
| `private_key_bytes` | `[32]u8` | Private_key_bytes |
| `addresses` | `[5]Address` | Addresses |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 15*

---

### `Address`

A blockchain address — includes the algorithm type, public key, and formatted address string.

| Field | Type | Description |
|-------|------|-------------|
| `domain` | `[]const u8` | Domain |
| `algorithm` | `[]const u8` | Algorithm |
| `omni_address` | `[]u8` | Omni_address |
| `coin_type` | `u32` | Coin_type |
| `security_level` | `u32` | Security_level |

*Defined at line 28*

---

### `PQSignResult`

Rezultatul semnarii pentru un domeniu PQ

| Field | Type | Description |
|-------|------|-------------|
| `domain` | `[]const u8` | Domain |
| `algorithm` | `[]const u8` | Algorithm |
| `signature` | `[]u8` | Signature |
| `success` | `bool` | Success |

*Defined at line 380*

---

## Functions

### `fromMnemonic()`

Creeaza wallet din mnemonic (BIP-39) si passphrase

```zig
pub fn fromMnemonic(mnemonic: []const u8, passphrase: []const u8, allocator: std.mem.Allocator) !Wallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `mnemonic` | `[]const u8` | Mnemonic |
| `passphrase` | `[]const u8` | Passphrase |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!Wallet`

*Defined at line 38*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *Wallet) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Wallet` | The instance |

*Defined at line 91*

---

### `getBalance()`

Returns the current balance.

```zig
pub fn getBalance(self: *const Wallet) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Wallet` | The instance |

**Returns:** `u64`

*Defined at line 101*

---

### `getBalanceOMNI()`

Returns the current balance o m n i.

```zig
pub fn getBalanceOMNI(self: *const Wallet) f64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Wallet` | The instance |

**Returns:** `f64`

*Defined at line 105*

---

### `canSend()`

Verifica daca ai suficienta balanta pentru un transfer

```zig
pub fn canSend(self: *const Wallet, amount_sat: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Wallet` | The instance |
| `amount_sat` | `u64` | Amount_sat |

**Returns:** `bool`

*Defined at line 110*

---

### `updateBalance()`

Actualizeaza balanta (apelat din RPC fetch)

```zig
pub fn updateBalance(self: *Wallet, new_balance_sat: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Wallet` | The instance |
| `new_balance_sat` | `u64` | New_balance_sat |

*Defined at line 115*

---

### `getAddress()`

Returns the address for the given index.

```zig
pub fn getAddress(self: *const Wallet, index: u32) ?Address {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Wallet` | The instance |
| `index` | `u32` | Index |

**Returns:** `?Address`

*Defined at line 119*

---

### `getAllAddresses()`

Returns the current all addresses.

```zig
pub fn getAllAddresses(self: *const Wallet) [5]Address {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Wallet` | The instance |

**Returns:** `[5]Address`

*Defined at line 124*

---

### `pubkeyHash160()`

Compute Hash160(pubkey) = RIPEMD160(SHA256(pubkey))
Used for P2PKH script generation

```zig
pub fn pubkeyHash160(compressed_pubkey: [33]u8) [20]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `compressed_pubkey` | `[33]u8` | Compressed_pubkey |

**Returns:** `[20]u8`

*Defined at line 227*

---

### `printAddresses()`

Performs the print addresses operation on the wallet module.

```zig
pub fn printAddresses(self: *const Wallet) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Wallet` | The instance |

*Defined at line 289*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
