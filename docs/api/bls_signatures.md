# Module: `bls_signatures`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `BlsPublicKey`

*Line: 31*

### `BlsSecretKey`

*Line: 46*

### `BlsSignature`

*Line: 56*

### `BlsThreshold`

BLS Threshold Signature (t-of-n)
Requires t out of n partial signatures to reconstruct full signature

*Line: 154*

## Constants

| Name | Type | Value |
|------|------|-------|
| `BLS_PUBKEY_SIZE` | auto | `usize = 48` |
| `BLS_SIG_SIZE` | auto | `usize = 96` |
| `BLS_SECKEY_SIZE` | auto | `usize = 32` |

## Functions

### `fromSecretKey`

```zig
pub fn fromSecretKey(secret: BlsSecretKey) BlsPublicKey {
```

**Parameters:**

- `secret`: `BlsSecretKey`

**Returns:** `BlsPublicKey`

*Line: 34*

---

### `generate`

```zig
pub fn generate() BlsSecretKey {
```

**Returns:** `BlsSecretKey`

*Line: 49*

---

### `toBytes`

Serialize to bytes

```zig
pub fn toBytes(self: *const BlsSignature) [BLS_SIG_SIZE]u8 {
```

**Parameters:**

- `self`: `*const BlsSignature`

**Returns:** `[BLS_SIG_SIZE]u8`

*Line: 60*

---

### `blsSign`

Sign a message with BLS secret key
sig = H(m)^sk (BLS12-381 pairing-based)

```zig
pub fn blsSign(secret: BlsSecretKey, message: []const u8) BlsSignature {
```

**Parameters:**

- `secret`: `BlsSecretKey`
- `message`: `[]const u8`

**Returns:** `BlsSignature`

*Line: 67*

---

### `blsVerify`

Verify a BLS signature
e(sig, G) == e(H(m), pk)  (pairing check)

```zig
pub fn blsVerify(pubkey: BlsPublicKey, message: []const u8, sig: BlsSignature) bool {
```

**Parameters:**

- `pubkey`: `BlsPublicKey`
- `message`: `[]const u8`
- `sig`: `BlsSignature`

**Returns:** `bool`

*Line: 92*

---

### `blsAggregate`

Aggregate multiple BLS signatures into one
agg_sig = sig_1 + sig_2 + ... + sig_n (EC point addition)
Verification: e(agg_sig, G) == e(H(m), pk_1 + pk_2 + ... + pk_n)

```zig
pub fn blsAggregate(signatures: []const BlsSignature) BlsSignature {
```

**Parameters:**

- `signatures`: `[]const BlsSignature`

**Returns:** `BlsSignature`

*Line: 117*

---

### `blsAggregateKeys`

Aggregate multiple BLS public keys

```zig
pub fn blsAggregateKeys(pubkeys: []const BlsPublicKey) BlsPublicKey {
```

**Parameters:**

- `pubkeys`: `[]const BlsPublicKey`

**Returns:** `BlsPublicKey`

*Line: 131*

---

### `init`

```zig
pub fn init(threshold: u8, total: u8) BlsThreshold {
```

**Parameters:**

- `threshold`: `u8`
- `total`: `u8`

**Returns:** `BlsThreshold`

*Line: 160*

---

### `addPartial`

Add a partial signature

```zig
pub fn addPartial(self: *BlsThreshold, sig: BlsSignature) !void {
```

**Parameters:**

- `self`: `*BlsThreshold`
- `sig`: `BlsSignature`

**Returns:** `!void`

*Line: 170*

---

### `isThresholdMet`

Check if threshold is met

```zig
pub fn isThresholdMet(self: *const BlsThreshold) bool {
```

**Parameters:**

- `self`: `*const BlsThreshold`

**Returns:** `bool`

*Line: 177*

---

### `reconstruct`

Reconstruct full signature from partials (Lagrange interpolation)

```zig
pub fn reconstruct(self: *const BlsThreshold) !BlsSignature {
```

**Parameters:**

- `self`: `*const BlsThreshold`

**Returns:** `!BlsSignature`

*Line: 182*

---

