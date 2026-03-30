# Module: `secp256k1`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Secp256k1Crypto`

secp256k1 — curba eliptica Bitcoin/OMNI
Foloseste std.crypto.sign.ecdsa (Zig 0.15 stdlib, zero dependente externe)

*Line: 7*

## Constants

| Name | Type | Value |
|------|------|-------|
| `CompressedPubkey` | auto | `[33]u8` |
| `PrivateKey` | auto | `[32]u8` |
| `Signature` | auto | `[64]u8` |

## Functions

### `privateKeyToPublicKey`

Genereaza compressed public key din private key

```zig
pub fn privateKeyToPublicKey(private_key: PrivateKey) !CompressedPubkey {
```

**Parameters:**

- `private_key`: `PrivateKey`

**Returns:** `!CompressedPubkey`

*Line: 18*

---

### `privateKeyToHash160`

Genereaza adresa Bitcoin-style din private key
privkey → pubkey → SHA256 → SHA256[0..20]
(SHA256[0..20] ca aproximare pentru RIPEMD-160 — see ripemd160.zig for full impl)

```zig
pub fn privateKeyToHash160(private_key: PrivateKey) ![20]u8 {
```

**Parameters:**

- `private_key`: `PrivateKey`

**Returns:** `![20]u8`

*Line: 27*

---

### `sign`

Semneaza un mesaj cu private key (ECDSA secp256k1 + SHA256d)

```zig
pub fn sign(private_key: PrivateKey, message: []const u8) !Signature {
```

**Parameters:**

- `private_key`: `PrivateKey`
- `message`: `[]const u8`

**Returns:** `!Signature`

*Line: 41*

---

### `verify`

Verifica semnatura unui mesaj cu public key

```zig
pub fn verify(compressed_pubkey: CompressedPubkey, message: []const u8, signature: Signature) bool {
```

**Parameters:**

- `compressed_pubkey`: `CompressedPubkey`
- `message`: `[]const u8`
- `signature`: `Signature`

**Returns:** `bool`

*Line: 49*

---

### `isValidPrivateKey`

Verifica daca o cheie privata e valida (in range [1, n-1])

```zig
pub fn isValidPrivateKey(private_key: PrivateKey) bool {
```

**Parameters:**

- `private_key`: `PrivateKey`

**Returns:** `bool`

*Line: 57*

---

### `generateKeyPair`

Genereaza o pereche de chei random (pentru teste/debug)

```zig
pub fn generateKeyPair() !struct { private_key: PrivateKey, public_key: CompressedPubkey } {
```

**Returns:** `!struct`

*Line: 78*

---

