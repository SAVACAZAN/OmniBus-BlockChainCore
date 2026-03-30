# Module: `bls_signatures`

> BLS threshold signatures (t-of-n) — aggregate multiple signatures into one, verify against aggregate public key, used for consensus efficiency.

**Source:** `core/bls_signatures.zig` | **Lines:** 294 | **Functions:** 11 | **Structs:** 4 | **Tests:** 10

---

## Contents

### Structs
- [`BlsPublicKey`](#blspublickey) — Data structure for bls public key. Fields include: bytes.
- [`BlsSecretKey`](#blssecretkey) — Data structure for bls secret key. Fields include: bytes.
- [`BlsSignature`](#blssignature) — Data structure for bls signature. Fields include: bytes.
- [`BlsThreshold`](#blsthreshold) — BLS Threshold Signature (t-of-n)
Requires t out of n partial signatures to recon...

### Constants
- [3 constants defined](#constants)

### Functions
- [`fromSecretKey()`](#fromsecretkey) — Performs the from secret key operation on the bls_signatures module.
- [`generate()`](#generate) — Performs the generate operation on the bls_signatures module.
- [`toBytes()`](#tobytes) — Serialize to bytes
- [`blsSign()`](#blssign) — Sign a message with BLS secret key
sig = H(m)^sk (BLS12-381 pairing-ba...
- [`blsVerify()`](#blsverify) — Verify a BLS signature
e(sig, G) == e(H(m), pk)  (pairing check)
- [`blsAggregate()`](#blsaggregate) — Aggregate multiple BLS signatures into one
agg_sig = sig_1 + sig_2 + ....
- [`blsAggregateKeys()`](#blsaggregatekeys) — Aggregate multiple BLS public keys
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addPartial()`](#addpartial) — Add a partial signature
- [`isThresholdMet()`](#isthresholdmet) — Check if threshold is met
- [`reconstruct()`](#reconstruct) — Reconstruct full signature from partials (Lagrange interpolation)

---

## Structs

### `BlsPublicKey`

Data structure for bls public key. Fields include: bytes.

| Field | Type | Description |
|-------|------|-------------|
| `bytes` | `[BLS_PUBKEY_SIZE]u8` | Bytes |

*Defined at line 31*

---

### `BlsSecretKey`

Data structure for bls secret key. Fields include: bytes.

| Field | Type | Description |
|-------|------|-------------|
| `bytes` | `[BLS_SECKEY_SIZE]u8` | Bytes |

*Defined at line 46*

---

### `BlsSignature`

Data structure for bls signature. Fields include: bytes.

| Field | Type | Description |
|-------|------|-------------|
| `bytes` | `[BLS_SIG_SIZE]u8` | Bytes |

*Defined at line 56*

---

### `BlsThreshold`

BLS Threshold Signature (t-of-n)
Requires t out of n partial signatures to reconstruct full signature

| Field | Type | Description |
|-------|------|-------------|
| `threshold` | `u8` | Threshold |
| `total` | `u8` | Total |
| `partial_sigs` | `[128]BlsSignature` | Partial_sigs |
| `partial_count` | `u8` | Partial_count |

*Defined at line 154*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `BLS_PUBKEY_SIZE` | `usize = 48` | B l s_ p u b k e y_ s i z e |
| `BLS_SIG_SIZE` | `usize = 96` | B l s_ s i g_ s i z e |
| `BLS_SECKEY_SIZE` | `usize = 32` | B l s_ s e c k e y_ s i z e |

---

## Functions

### `fromSecretKey()`

Performs the from secret key operation on the bls_signatures module.

```zig
pub fn fromSecretKey(secret: BlsSecretKey) BlsPublicKey {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `secret` | `BlsSecretKey` | Secret |

**Returns:** `BlsPublicKey`

*Defined at line 34*

---

### `generate()`

Performs the generate operation on the bls_signatures module.

```zig
pub fn generate() BlsSecretKey {
```

**Returns:** `BlsSecretKey`

*Defined at line 49*

---

### `toBytes()`

Serialize to bytes

```zig
pub fn toBytes(self: *const BlsSignature) [BLS_SIG_SIZE]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlsSignature` | The instance |

**Returns:** `[BLS_SIG_SIZE]u8`

*Defined at line 60*

---

### `blsSign()`

Sign a message with BLS secret key
sig = H(m)^sk (BLS12-381 pairing-based)

```zig
pub fn blsSign(secret: BlsSecretKey, message: []const u8) BlsSignature {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `secret` | `BlsSecretKey` | Secret |
| `message` | `[]const u8` | Message |

**Returns:** `BlsSignature`

*Defined at line 67*

---

### `blsVerify()`

Verify a BLS signature
e(sig, G) == e(H(m), pk)  (pairing check)

```zig
pub fn blsVerify(pubkey: BlsPublicKey, message: []const u8, sig: BlsSignature) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `pubkey` | `BlsPublicKey` | Pubkey |
| `message` | `[]const u8` | Message |
| `sig` | `BlsSignature` | Sig |

**Returns:** `bool`

*Defined at line 92*

---

### `blsAggregate()`

Aggregate multiple BLS signatures into one
agg_sig = sig_1 + sig_2 + ... + sig_n (EC point addition)
Verification: e(agg_sig, G) == e(H(m), pk_1 + pk_2 + ... + pk_n)

```zig
pub fn blsAggregate(signatures: []const BlsSignature) BlsSignature {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `signatures` | `[]const BlsSignature` | Signatures |

**Returns:** `BlsSignature`

*Defined at line 117*

---

### `blsAggregateKeys()`

Aggregate multiple BLS public keys

```zig
pub fn blsAggregateKeys(pubkeys: []const BlsPublicKey) BlsPublicKey {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `pubkeys` | `[]const BlsPublicKey` | Pubkeys |

**Returns:** `BlsPublicKey`

*Defined at line 131*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(threshold: u8, total: u8) BlsThreshold {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `threshold` | `u8` | Threshold |
| `total` | `u8` | Total |

**Returns:** `BlsThreshold`

*Defined at line 160*

---

### `addPartial()`

Add a partial signature

```zig
pub fn addPartial(self: *BlsThreshold, sig: BlsSignature) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BlsThreshold` | The instance |
| `sig` | `BlsSignature` | Sig |

**Returns:** `!void`

*Defined at line 170*

---

### `isThresholdMet()`

Check if threshold is met

```zig
pub fn isThresholdMet(self: *const BlsThreshold) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlsThreshold` | The instance |

**Returns:** `bool`

*Defined at line 177*

---

### `reconstruct()`

Reconstruct full signature from partials (Lagrange interpolation)

```zig
pub fn reconstruct(self: *const BlsThreshold) !BlsSignature {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlsThreshold` | The instance |

**Returns:** `!BlsSignature`

*Defined at line 182*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
