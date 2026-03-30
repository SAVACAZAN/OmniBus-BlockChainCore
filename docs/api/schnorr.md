# Module: `schnorr`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `SchnorrSignature`

BIP-340 Schnorr Signatures over secp256k1
- 64-byte signatures (vs 71 for ECDSA DER)
- Linear: sig(m, sk1) + sig(m, sk2) = sig(m, sk1+sk2) → enables MuSig2
- Batch verification: verify N sigs faster than N individual verifications
- Provably secure under DL assumption in Random Oracle Model

Reference: https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki

*Line: 13*

### `SchnorrPubKey`

Schnorr public key (x-only, 32 bytes — BIP-340 standard)
Unlike ECDSA compressed keys (33 bytes with parity prefix),
Schnorr uses x-only keys (32 bytes, implicit even Y)

*Line: 36*

## Functions

### `toBytes`

```zig
pub fn toBytes(self: *const SchnorrSignature) [64]u8 {
```

**Parameters:**

- `self`: `*const SchnorrSignature`

**Returns:** `[64]u8`

*Line: 18*

---

### `fromBytes`

```zig
pub fn fromBytes(bytes: [64]u8) SchnorrSignature {
```

**Parameters:**

- `bytes`: `[64]u8`

**Returns:** `SchnorrSignature`

*Line: 25*

---

### `fromCompressed`

Convert from compressed ECDSA pubkey (33 bytes) to x-only (32 bytes)

```zig
pub fn fromCompressed(compressed: [33]u8) SchnorrPubKey {
```

**Parameters:**

- `compressed`: `[33]u8`

**Returns:** `SchnorrPubKey`

*Line: 40*

---

### `schnorrSign`

BIP-340 Schnorr sign
Signs message with private key using deterministic nonce (RFC 6979 style)

Algorithm:
1. d = private_key (scalar)
2. P = d*G (public key point)
3. If P.y is odd, negate d (ensure even Y)
4. t = xor(bytes(d), tagged_hash("BIP0340/aux", a))
5. rand = tagged_hash("BIP0340/nonce", t || bytes(P) || m)
6. k = int(rand) mod n
7. R = k*G; if R.y is odd, negate k
8. e = int(tagged_hash("BIP0340/challenge", bytes(R) || bytes(P) || m)) mod n
9. sig = bytes(R) || bytes((k + e*d) mod n)

```zig
pub fn schnorrSign(private_key: [32]u8, message: []const u8) SchnorrSignature {
```

**Parameters:**

- `private_key`: `[32]u8`
- `message`: `[]const u8`

**Returns:** `SchnorrSignature`

*Line: 76*

---

### `schnorrVerify`

BIP-340 Schnorr verify
Verifies signature (R, s) against public key P and message m

Algorithm:
1. P = lift_x(pubkey.x)
2. e = int(tagged_hash("BIP0340/challenge", bytes(R) || bytes(P) || m)) mod n
3. R' = s*G - e*P
4. Verify: R'.x == R.x and R'.y is even

```zig
pub fn schnorrVerify(pubkey: SchnorrPubKey, message: []const u8, sig: SchnorrSignature) bool {
```

**Parameters:**

- `pubkey`: `SchnorrPubKey`
- `message`: `[]const u8`
- `sig`: `SchnorrSignature`

**Returns:** `bool`

*Line: 121*

---

### `tweakPubkey`

Key tweaking for Taproot (BIP-341)
tweaked_key = internal_key + tagged_hash("TapTweak", internal_key || merkle_root) * G

```zig
pub fn tweakPubkey(internal_key: SchnorrPubKey, merkle_root: [32]u8) SchnorrPubKey {
```

**Parameters:**

- `internal_key`: `SchnorrPubKey`
- `merkle_root`: `[32]u8`

**Returns:** `SchnorrPubKey`

*Line: 183*

---

