# Module: `transaction`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Transaction`

*Line: 9*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MAX_OP_RETURN` | auto | `usize = 80` |

## Functions

### `calculateHash`

Calculeaza hash-ul tranzactiei (SHA256d — Bitcoin style)
Hash = SHA256(SHA256(id || from || to || amount || timestamp || nonce))
Nonce inclus in hash previne replay attacks (aceeasi TX cu nonce diferit = hash diferit)

```zig
pub fn calculateHash(self: *const Transaction) [32]u8 {
```

**Parameters:**

- `self`: `*const Transaction`

**Returns:** `[32]u8`

*Line: 43*

---

### `isValid`

Valideaza tranzactia: amount > 0, adrese cu prefix corect

```zig
pub fn isValid(self: *const Transaction) bool {
```

**Parameters:**

- `self`: `*const Transaction`

**Returns:** `bool`

*Line: 62*

---

### `sign`

Semneaza tranzactia cu private key (secp256k1 ECDSA SHA256d — REAL)
Seteaza self.signature = hex(R||S) si self.hash = hex(tx_hash)

```zig
pub fn sign(self: *Transaction, private_key: [32]u8, allocator: std.mem.Allocator) !void {
```

**Parameters:**

- `self`: `*Transaction`
- `private_key`: `[32]u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!void`

*Line: 79*

---

### `verify`

Verifica semnatura tranzactiei cu public key (secp256k1 ECDSA — REAL)

```zig
pub fn verify(self: *const Transaction, compressed_pubkey: [33]u8) bool {
```

**Parameters:**

- `self`: `*const Transaction`
- `compressed_pubkey`: `[33]u8`

**Returns:** `bool`

*Line: 92*

---

### `verifyWithHexPubkey`

Verifica semnatura cu public key in format hex (66 chars)

```zig
pub fn verifyWithHexPubkey(self: *const Transaction, pubkey_hex: []const u8) bool {
```

**Parameters:**

- `self`: `*const Transaction`
- `pubkey_hex`: `[]const u8`

**Returns:** `bool`

*Line: 112*

---

