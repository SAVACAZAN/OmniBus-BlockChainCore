# Module: `multisig`

> M-of-N multisig — create multisig addresses, collect signatures, verify threshold, timelock contracts for delayed execution.

**Source:** `core/multisig.zig` | **Lines:** 664 | **Functions:** 14 | **Structs:** 5 | **Tests:** 21

---

## Contents

### Structs
- [`MultisigConfig`](#multisigconfig) — M-of-N MultiSig configuration
Requires M out of N public keys to authorize a tra...
- [`MultisigSignature`](#multisigsignature) — Collected signature for multisig verification
- [`TimelockMultisig`](#timelockmultisig) — Timelock: multisig with time constraints (for payment channels / escrow)
- [`MultisigWallet`](#multisigwallet) — A MultisigWallet holds the M-of-N configuration and derives an "ob_ms_" address....
- [`MultisigTx`](#multisigtx) — A multisig transaction that accumulates signatures from multiple signers.

### Constants
- [3 constants defined](#constants)

### Functions
- [`init()`](#init) — Create a new M-of-N multisig config
- [`address()`](#address) — Generate the multisig address (hash of config)
address = "ob_ms_" + he...
- [`containsPubkey()`](#containspubkey) — Check if a public key is part of this multisig
- [`serialize()`](#serialize) — Serialize config for storage/transmission
- [`isLocked()`](#islocked) — Checks whether the locked condition is true.
- [`create()`](#create) — Create an M-of-N multisig wallet from a set of compressed public keys....
- [`getAddress()`](#getaddress) — Return the multisig address as a slice.
- [`createTx()`](#createtx) — Create an unsigned MultisigTx from this wallet.
- [`addSignature()`](#addsignature) — Add a signature from a private key. Returns true when threshold is met...
- [`verify()`](#verify) — Verify all collected signatures on a MultisigTx.
- [`txHash()`](#txhash) — Compute the transaction hash that signers sign over.
- [`isComplete()`](#iscomplete) — Return true if enough signatures have been collected.
- [`fromAddress()`](#fromaddress) — Get the "from" address as a slice.
- [`toAddress()`](#toaddress) — Get the "to" address as a slice.

---

## Structs

### `MultisigConfig`

M-of-N MultiSig configuration
Requires M out of N public keys to authorize a transaction
Compatible with Bitcoin P2SH multisig concept

| Field | Type | Description |
|-------|------|-------------|
| `threshold` | `u8` | Threshold |
| `total` | `u8` | Total |

*Defined at line 19*

---

### `MultisigSignature`

Collected signature for multisig verification

| Field | Type | Description |
|-------|------|-------------|
| `signer_index` | `u8` | Signer_index |
| `signature` | `[64]u8` | Signature |

*Defined at line 86*

---

### `TimelockMultisig`

Timelock: multisig with time constraints (for payment channels / escrow)

| Field | Type | Description |
|-------|------|-------------|
| `config` | `MultisigConfig` | Config |
| `lock_until_block` | `u64` | Lock_until_block |
| `recovery_pubkey` | `[33]u8` | Recovery_pubkey |
| `self` | `*const TimelockMultisig` | Self |
| `message_hash` | `[32]u8` | Message_hash |
| `signatures` | `[]const MultisigSignature` | Signatures |
| `current_block` | `u64` | Current_block |

*Defined at line 154*

---

### `MultisigWallet`

A MultisigWallet holds the M-of-N configuration and derives an "ob_ms_" address.
It can create unsigned transactions and collect signatures until the threshold is met.

| Field | Type | Description |
|-------|------|-------------|
| `config` | `MultisigConfig` | Config |
| `address` | `[64]u8` | Address |
| `address_len` | `u8` | Address_len |

*Defined at line 198*

---

### `MultisigTx`

A multisig transaction that accumulates signatures from multiple signers.

| Field | Type | Description |
|-------|------|-------------|
| `from_address` | `[64]u8` | From_address |
| `from_len` | `u8` | From_len |
| `to_address_buf` | `[64]u8` | To_address_buf |
| `to_len` | `u8` | To_len |
| `amount` | `u64` | Amount |
| `fee` | `u64` | Fee |
| `tx_id` | `u32` | Tx_id |
| `signatures` | `[MAX_SIGNERS][64]u8` | Signatures |
| `signer_indices` | `[MAX_SIGNERS]u8` | Signer_indices |
| `sig_count` | `u8` | Sig_count |
| `signed_by` | `[MAX_SIGNERS]bool` | Signed_by |
| `config` | `MultisigConfig` | Config |

*Defined at line 316*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MAX_SIGNERS` | `usize = 16` | M a x_ s i g n e r s |
| `MAX_SIGNATURES` | `usize = 16` | M a x_ s i g n a t u r e s |
| `MULTISIG_PREFIX` | `"ob_ms_"` | M u l t i s i g_ p r e f i x |

---

## Functions

### `init()`

Create a new M-of-N multisig config

```zig
pub fn init(threshold: u8, pubkeys: []const [33]u8) !MultisigConfig {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `threshold` | `u8` | Threshold |
| `pubkeys` | `[]const [33]u8` | Pubkeys |

**Returns:** `!MultisigConfig`

*Defined at line 30*

---

### `address()`

Generate the multisig address (hash of config)
address = "ob_ms_" + hex(SHA256(threshold || N || pk1 || pk2 || ... || pkN))[0..32]

```zig
pub fn address(self: *const MultisigConfig) [32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigConfig` | The instance |

**Returns:** `[32]u8`

*Defined at line 52*

---

### `containsPubkey()`

Check if a public key is part of this multisig

```zig
pub fn containsPubkey(self: *const MultisigConfig, pubkey: [33]u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigConfig` | The instance |
| `pubkey` | `[33]u8` | Pubkey |

**Returns:** `bool`

*Defined at line 65*

---

### `serialize()`

Serialize config for storage/transmission

```zig
pub fn serialize(self: *const MultisigConfig) [2 + MAX_SIGNERS * 33]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigConfig` | The instance |

**Returns:** `[2 + MAX_SIGNERS * 33]u8`

*Defined at line 73*

---

### `isLocked()`

Checks whether the locked condition is true.

```zig
pub fn isLocked(self: *const TimelockMultisig, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const TimelockMultisig` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 161*

---

### `create()`

Create an M-of-N multisig wallet from a set of compressed public keys.
The address is derived as "ob_ms_" + hex(SHA256(M || N || sorted_pubkeys))[0..32].

```zig
pub fn create(required: u8, pubkeys: []const [33]u8) !MultisigWallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `required` | `u8` | Required |
| `pubkeys` | `[]const [33]u8` | Pubkeys |

**Returns:** `!MultisigWallet`

*Defined at line 205*

---

### `getAddress()`

Return the multisig address as a slice.

```zig
pub fn getAddress(self: *const MultisigWallet) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigWallet` | The instance |

**Returns:** `[]const u8`

*Defined at line 251*

---

### `createTx()`

Create an unsigned MultisigTx from this wallet.

```zig
pub fn createTx(self: *const MultisigWallet, to: []const u8, amount: u64, fee: u64, tx_id: u32) MultisigTx {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigWallet` | The instance |
| `to` | `[]const u8` | To |
| `amount` | `u64` | Amount |
| `fee` | `u64` | Fee |
| `tx_id` | `u32` | Tx_id |

**Returns:** `MultisigTx`

*Defined at line 256*

---

### `addSignature()`

Add a signature from a private key. Returns true when threshold is met.

```zig
pub fn addSignature(self: *const MultisigWallet, tx: *MultisigTx, privkey: [32]u8) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigWallet` | The instance |
| `tx` | `*MultisigTx` | Tx |
| `privkey` | `[32]u8` | Privkey |

**Returns:** `!bool`

*Defined at line 279*

---

### `verify()`

Verify all collected signatures on a MultisigTx.

```zig
pub fn verify(self: *const MultisigWallet, tx: *const MultisigTx) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigWallet` | The instance |
| `tx` | `*const MultisigTx` | Tx |

**Returns:** `bool`

*Defined at line 292*

---

### `txHash()`

Compute the transaction hash that signers sign over.

```zig
pub fn txHash(self: *const MultisigTx) [32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigTx` | The instance |

**Returns:** `[32]u8`

*Defined at line 331*

---

### `isComplete()`

Return true if enough signatures have been collected.

```zig
pub fn isComplete(self: *const MultisigTx) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigTx` | The instance |

**Returns:** `bool`

*Defined at line 361*

---

### `fromAddress()`

Get the "from" address as a slice.

```zig
pub fn fromAddress(self: *const MultisigTx) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigTx` | The instance |

**Returns:** `[]const u8`

*Defined at line 366*

---

### `toAddress()`

Get the "to" address as a slice.

```zig
pub fn toAddress(self: *const MultisigTx) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MultisigTx` | The instance |

**Returns:** `[]const u8`

*Defined at line 371*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
