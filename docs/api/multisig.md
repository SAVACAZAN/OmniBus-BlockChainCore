# Module: `multisig`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `MultisigConfig`

M-of-N MultiSig configuration
Requires M out of N public keys to authorize a transaction
Compatible with Bitcoin P2SH multisig concept

*Line: 19*

### `MultisigSignature`

Collected signature for multisig verification

*Line: 86*

### `TimelockMultisig`

Timelock: multisig with time constraints (for payment channels / escrow)

*Line: 154*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MAX_SIGNERS` | auto | `usize = 15` |
| `MAX_SIGNATURES` | auto | `usize = 15` |
| `MULTISIG_PREFIX` | auto | `"ob_ms_"` |

## Functions

### `init`

Create a new M-of-N multisig config

```zig
pub fn init(threshold: u8, pubkeys: []const [33]u8) !MultisigConfig {
```

**Parameters:**

- `threshold`: `u8`
- `pubkeys`: `[]const [33]u8`

**Returns:** `!MultisigConfig`

*Line: 30*

---

### `address`

Generate the multisig address (hash of config)
address = "ob_ms_" + hex(SHA256(threshold || N || pk1 || pk2 || ... || pkN))[0..32]

```zig
pub fn address(self: *const MultisigConfig) [32]u8 {
```

**Parameters:**

- `self`: `*const MultisigConfig`

**Returns:** `[32]u8`

*Line: 52*

---

### `containsPubkey`

Check if a public key is part of this multisig

```zig
pub fn containsPubkey(self: *const MultisigConfig, pubkey: [33]u8) bool {
```

**Parameters:**

- `self`: `*const MultisigConfig`
- `pubkey`: `[33]u8`

**Returns:** `bool`

*Line: 65*

---

### `serialize`

Serialize config for storage/transmission

```zig
pub fn serialize(self: *const MultisigConfig) [2 + MAX_SIGNERS * 33]u8 {
```

**Parameters:**

- `self`: `*const MultisigConfig`

**Returns:** `[2 + MAX_SIGNERS * 33]u8`

*Line: 73*

---

### `isLocked`

```zig
pub fn isLocked(self: *const TimelockMultisig, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const TimelockMultisig`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 161*

---

