# Module: `bip32_wallet`

> BIP-32 HD wallet derivation — HMAC-SHA512 master key generation from seed, child key derivation (normal and hardened), BIP-44 path support for 5 PQ domains.

**Source:** `core/bip32_wallet.zig` | **Lines:** 399 | **Functions:** 12 | **Structs:** 3 | **Tests:** 8

---

## Contents

### Structs
- [`BIP32Wallet`](#bip32wallet) — BIP-32 Hierarchical Deterministic Wallet
HMAC-SHA512 real + secp256k1 real pentr...
- [`PQDomainDerivation`](#pqdomainderivation) — Manager pentru cele 5 domenii Post-Quantum OmniBus
- [`Domain`](#domain) — Data structure for domain. Fields include: name, algorithm, prefix, coin_type, s...

### Constants
- [1 constants defined](#constants)

### Functions
- [`initFromMnemonic()`](#initfrommnemonic) — Init din mnemonic — BIP-39 COMPLET
PBKDF2-HMAC-SHA512(password=mnemoni...
- [`initFromMnemonicPassphrase()`](#initfrommnemonicpassphrase) — BIP-39 cu passphrase optionala
- [`initFromSeed()`](#initfromseed) — Init din seed raw 64 bytes (output BIP-39 PBKDF2)
BIP-32 master: IL||I...
- [`deriveChildKey()`](#derivechildkey) — Deriva cheie la m/44'/0'/0'/0/index
- [`deriveChildKeyForPath()`](#derivechildkeyforpath) — Deriva cheie la m/purpose'/coin_type'/0'/0/index (BIP-44)
- [`derivePublicKey()`](#derivepublickey) — Genereaza compressed public key din cheie derivata
Acum REAL: secp256k...
- [`deriveAddress()`](#deriveaddress) — Genereaza adresa din cheie derivata — Base58Check(0x4F || hash160)
- [`deriveAddressForDomain()`](#deriveaddressfordomain) — Genereaza adresa pentru domeniu PQ — Base58Check(0x4F || hash160)
- [`base58CheckEncode()`](#base58checkencode) — Base58Check(version_byte || hash160) — identic cu Bitcoin/OmniBus Pyth...
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deriveAllAddresses()`](#derivealladdresses) — Performs the derive all addresses operation on the bip32_wallet module...
- [`getDomain()`](#getdomain) — Returns the domain for the given index.

---

## Structs

### `BIP32Wallet`

BIP-32 Hierarchical Deterministic Wallet
HMAC-SHA512 real + secp256k1 real pentru compressed pubkey

| Field | Type | Description |
|-------|------|-------------|
| `master_seed` | `[64]u8` | Master_seed |
| `master_key` | `[32]u8` | Master_key |
| `master_chain_code` | `[32]u8` | Master_chain_code |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 10*

---

### `PQDomainDerivation`

Manager pentru cele 5 domenii Post-Quantum OmniBus

| Field | Type | Description |
|-------|------|-------------|
| `wallet` | `BIP32Wallet` | Wallet |

*Defined at line 272*

---

### `Domain`

Data structure for domain. Fields include: name, algorithm, prefix, coin_type, security_level.

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Name |
| `algorithm` | `[]const u8` | Algorithm |
| `prefix` | `[]const u8` | Prefix |
| `coin_type` | `u32` | Coin_type |
| `security_level` | `u32` | Security_level |

*Defined at line 275*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `DOMAINS` | `[_]Domain{` | D o m a i n s |

---

## Functions

### `initFromMnemonic()`

Init din mnemonic — BIP-39 COMPLET
PBKDF2-HMAC-SHA512(password=mnemonic, salt="mnemonic"+passphrase, c=2048, dkLen=64)
Identic cu toate implementarile BIP-39 standard (Bitcoin, Ethereum, etc.)

```zig
pub fn initFromMnemonic(mnemonic: []const u8, allocator: std.mem.Allocator) !BIP32Wallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `mnemonic` | `[]const u8` | Mnemonic |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!BIP32Wallet`

*Defined at line 21*

---

### `initFromMnemonicPassphrase()`

BIP-39 cu passphrase optionala

```zig
pub fn initFromMnemonicPassphrase(mnemonic: []const u8, passphrase: []const u8, allocator: std.mem.Allocator) !BIP32Wallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `mnemonic` | `[]const u8` | Mnemonic |
| `passphrase` | `[]const u8` | Passphrase |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!BIP32Wallet`

*Defined at line 26*

---

### `initFromSeed()`

Init din seed raw 64 bytes (output BIP-39 PBKDF2)
BIP-32 master: IL||IR = HMAC-SHA512("Bitcoin seed", seed)

```zig
pub fn initFromSeed(seed: [64]u8, allocator: std.mem.Allocator) !BIP32Wallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `seed` | `[64]u8` | Seed |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!BIP32Wallet`

*Defined at line 49*

---

### `deriveChildKey()`

Deriva cheie la m/44'/0'/0'/0/index

```zig
pub fn deriveChildKey(self: *const BIP32Wallet, index: u32) ![32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BIP32Wallet` | The instance |
| `index` | `u32` | Index |

**Returns:** `![32]u8`

*Defined at line 67*

---

### `deriveChildKeyForPath()`

Deriva cheie la m/purpose'/coin_type'/0'/0/index (BIP-44)

```zig
pub fn deriveChildKeyForPath(self: *const BIP32Wallet, purpose: u32, coin_type: u32, index: u32) ![32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BIP32Wallet` | The instance |
| `purpose` | `u32` | Purpose |
| `coin_type` | `u32` | Coin_type |
| `index` | `u32` | Index |

**Returns:** `![32]u8`

*Defined at line 72*

---

### `derivePublicKey()`

Genereaza compressed public key din cheie derivata
Acum REAL: secp256k1 point multiply

```zig
pub fn derivePublicKey(self: *const BIP32Wallet, index: u32) ![33]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BIP32Wallet` | The instance |
| `index` | `u32` | Index |

**Returns:** `![33]u8`

*Defined at line 184*

---

### `deriveAddress()`

Genereaza adresa din cheie derivata — Base58Check(0x4F || hash160)

```zig
pub fn deriveAddress(self: *const BIP32Wallet, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BIP32Wallet` | The instance |
| `index` | `u32` | Index |
| `prefix` | `[]const u8` | Prefix |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 190*

---

### `deriveAddressForDomain()`

Genereaza adresa pentru domeniu PQ — Base58Check(0x4F || hash160)

```zig
pub fn deriveAddressForDomain(self: *const BIP32Wallet, coin_type: u32, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BIP32Wallet` | The instance |
| `coin_type` | `u32` | Coin_type |
| `index` | `u32` | Index |
| `prefix` | `[]const u8` | Prefix |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 199*

---

### `base58CheckEncode()`

Base58Check(version_byte || hash160) — identic cu Bitcoin/OmniBus Python
Output: Base58 string alocat cu allocator (caller trebuie sa elibereze)

```zig
pub fn base58CheckEncode(hash160: [20]u8, version: u8, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `hash160` | `[20]u8` | Hash160 |
| `version` | `u8` | Version |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 214*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(wallet: BIP32Wallet) PQDomainDerivation {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `wallet` | `BIP32Wallet` | Wallet |

**Returns:** `PQDomainDerivation`

*Defined at line 291*

---

### `deriveAllAddresses()`

Performs the derive all addresses operation on the bip32_wallet module.

```zig
pub fn deriveAllAddresses(self: *const PQDomainDerivation, allocator: std.mem.Allocator) ![5][]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PQDomainDerivation` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![5][]u8`

*Defined at line 295*

---

### `getDomain()`

Returns the domain for the given index.

```zig
pub fn getDomain(index: u32) ?Domain {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `index` | `u32` | Index |

**Returns:** `?Domain`

*Defined at line 303*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
