# Module: `bip32_wallet`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `BIP32Wallet`

BIP-32 Hierarchical Deterministic Wallet
HMAC-SHA512 real + secp256k1 real pentru compressed pubkey

*Line: 10*

### `PQDomainDerivation`

Manager pentru cele 5 domenii Post-Quantum OmniBus

*Line: 272*

### `Domain`

*Line: 275*

## Constants

| Name | Type | Value |
|------|------|-------|
| `DOMAINS` | auto | `[_]Domain{` |

## Functions

### `initFromMnemonic`

Init din mnemonic — BIP-39 COMPLET
PBKDF2-HMAC-SHA512(password=mnemonic, salt="mnemonic"+passphrase, c=2048, dkLen=64)
Identic cu toate implementarile BIP-39 standard (Bitcoin, Ethereum, etc.)

```zig
pub fn initFromMnemonic(mnemonic: []const u8, allocator: std.mem.Allocator) !BIP32Wallet {
```

**Parameters:**

- `mnemonic`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!BIP32Wallet`

*Line: 21*

---

### `initFromMnemonicPassphrase`

BIP-39 cu passphrase optionala

```zig
pub fn initFromMnemonicPassphrase(mnemonic: []const u8, passphrase: []const u8, allocator: std.mem.Allocator) !BIP32Wallet {
```

**Parameters:**

- `mnemonic`: `[]const u8`
- `passphrase`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!BIP32Wallet`

*Line: 26*

---

### `initFromSeed`

Init din seed raw 64 bytes (output BIP-39 PBKDF2)
BIP-32 master: IL||IR = HMAC-SHA512("Bitcoin seed", seed)

```zig
pub fn initFromSeed(seed: [64]u8, allocator: std.mem.Allocator) !BIP32Wallet {
```

**Parameters:**

- `seed`: `[64]u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!BIP32Wallet`

*Line: 49*

---

### `deriveChildKey`

Deriva cheie la m/44'/0'/0'/0/index

```zig
pub fn deriveChildKey(self: *const BIP32Wallet, index: u32) ![32]u8 {
```

**Parameters:**

- `self`: `*const BIP32Wallet`
- `index`: `u32`

**Returns:** `![32]u8`

*Line: 67*

---

### `deriveChildKeyForPath`

Deriva cheie la m/purpose'/coin_type'/0'/0/index (BIP-44)

```zig
pub fn deriveChildKeyForPath(self: *const BIP32Wallet, purpose: u32, coin_type: u32, index: u32) ![32]u8 {
```

**Parameters:**

- `self`: `*const BIP32Wallet`
- `purpose`: `u32`
- `coin_type`: `u32`
- `index`: `u32`

**Returns:** `![32]u8`

*Line: 72*

---

### `derivePublicKey`

Genereaza compressed public key din cheie derivata
Acum REAL: secp256k1 point multiply

```zig
pub fn derivePublicKey(self: *const BIP32Wallet, index: u32) ![33]u8 {
```

**Parameters:**

- `self`: `*const BIP32Wallet`
- `index`: `u32`

**Returns:** `![33]u8`

*Line: 184*

---

### `deriveAddress`

Genereaza adresa din cheie derivata — Base58Check(0x4F || hash160)

```zig
pub fn deriveAddress(self: *const BIP32Wallet, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const BIP32Wallet`
- `index`: `u32`
- `prefix`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 190*

---

### `deriveAddressForDomain`

Genereaza adresa pentru domeniu PQ — Base58Check(0x4F || hash160)

```zig
pub fn deriveAddressForDomain(self: *const BIP32Wallet, coin_type: u32, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const BIP32Wallet`
- `coin_type`: `u32`
- `index`: `u32`
- `prefix`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 199*

---

### `base58CheckEncode`

Base58Check(version_byte || hash160) — identic cu Bitcoin/OmniBus Python
Output: Base58 string alocat cu allocator (caller trebuie sa elibereze)

```zig
pub fn base58CheckEncode(hash160: [20]u8, version: u8, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `hash160`: `[20]u8`
- `version`: `u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 214*

---

### `init`

```zig
pub fn init(wallet: BIP32Wallet) PQDomainDerivation {
```

**Parameters:**

- `wallet`: `BIP32Wallet`

**Returns:** `PQDomainDerivation`

*Line: 291*

---

### `deriveAllAddresses`

```zig
pub fn deriveAllAddresses(self: *const PQDomainDerivation, allocator: std.mem.Allocator) ![5][]u8 {
```

**Parameters:**

- `self`: `*const PQDomainDerivation`
- `allocator`: `std.mem.Allocator`

**Returns:** `![5][]u8`

*Line: 295*

---

### `getDomain`

```zig
pub fn getDomain(index: u32) ?Domain {
```

**Parameters:**

- `index`: `u32`

**Returns:** `?Domain`

*Line: 303*

---

