# Module: `wallet`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `Wallet`

OmniBus Wallet — derivare reala BIP32 + secp256k1

*Line: 11*

### `Address`

*Line: 24*

### `PQSignResult`

Rezultatul semnarii pentru un domeniu PQ

*Line: 237*

## Functions

### `fromMnemonic`

Creeaza wallet din mnemonic (BIP-39) si passphrase

```zig
pub fn fromMnemonic(mnemonic: []const u8, passphrase: []const u8, allocator: std.mem.Allocator) !Wallet {
```

**Parameters:**

- `mnemonic`: `[]const u8`
- `passphrase`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!Wallet`

*Line: 34*

---

### `deinit`

```zig
pub fn deinit(self: *Wallet) void {
```

**Parameters:**

- `self`: `*Wallet`

*Line: 87*

---

### `getBalance`

```zig
pub fn getBalance(self: *const Wallet) u64 {
```

**Parameters:**

- `self`: `*const Wallet`

**Returns:** `u64`

*Line: 97*

---

### `getBalanceOMNI`

```zig
pub fn getBalanceOMNI(self: *const Wallet) f64 {
```

**Parameters:**

- `self`: `*const Wallet`

**Returns:** `f64`

*Line: 101*

---

### `canSend`

Verifica daca ai suficienta balanta pentru un transfer

```zig
pub fn canSend(self: *const Wallet, amount_sat: u64) bool {
```

**Parameters:**

- `self`: `*const Wallet`
- `amount_sat`: `u64`

**Returns:** `bool`

*Line: 106*

---

### `updateBalance`

Actualizeaza balanta (apelat din RPC fetch)

```zig
pub fn updateBalance(self: *Wallet, new_balance_sat: u64) void {
```

**Parameters:**

- `self`: `*Wallet`
- `new_balance_sat`: `u64`

*Line: 111*

---

### `getAddress`

```zig
pub fn getAddress(self: *const Wallet, index: u32) ?Address {
```

**Parameters:**

- `self`: `*const Wallet`
- `index`: `u32`

**Returns:** `?Address`

*Line: 115*

---

### `getAllAddresses`

```zig
pub fn getAllAddresses(self: *const Wallet) [5]Address {
```

**Parameters:**

- `self`: `*const Wallet`

**Returns:** `[5]Address`

*Line: 120*

---

### `printAddresses`

```zig
pub fn printAddresses(self: *const Wallet) void {
```

**Parameters:**

- `self`: `*const Wallet`

*Line: 146*

---

