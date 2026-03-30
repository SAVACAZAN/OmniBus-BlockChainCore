# Module: `finality`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Checkpoint`

A checkpoint in the finality chain

*Line: 40*

### `Attestation`

Attestation from a validator

*Line: 67*

### `SlashingEvidence`

Slashing condition: equivocation (voting for two different blocks at same epoch)

*Line: 82*

### `FinalityEngine`

Finality Engine

*Line: 92*

## Constants

| Name | Type | Value |
|------|------|-------|
| `CHECKPOINT_INTERVAL` | auto | `u64 = 64` |
| `SOFT_FINALITY_CONFIRMS` | auto | `u32 = 6` |
| `MAX_CHECKPOINTS` | auto | `usize = 256` |
| `MAX_VALIDATORS` | auto | `usize = 128` |
| `CheckpointStatus` | auto | `enum(u8) {` |

## Functions

### `hasSupermajority`

Check if this checkpoint has supermajority (2/3+)

```zig
pub fn hasSupermajority(self: *const Checkpoint, total_power: u64) bool {
```

**Parameters:**

- `self`: `*const Checkpoint`
- `total_power`: `u64`

**Returns:** `bool`

*Line: 59*

---

### `init`

```zig
pub fn init(total_voting_power: u64) FinalityEngine {
```

**Parameters:**

- `total_voting_power`: `u64`

**Returns:** `FinalityEngine`

*Line: 108*

---

### `proposeCheckpoint`

Propose a new checkpoint at given block height

```zig
pub fn proposeCheckpoint(self: *FinalityEngine, block_height: u64, block_hash: [32]u8) !u64 {
```

**Parameters:**

- `self`: `*FinalityEngine`
- `block_height`: `u64`
- `block_hash`: `[32]u8`

**Returns:** `!u64`

*Line: 135*

---

### `attest`

Submit an attestation for a checkpoint

```zig
pub fn attest(self: *FinalityEngine, attestation: Attestation) !void {
```

**Parameters:**

- `self`: `*FinalityEngine`
- `attestation`: `Attestation`

**Returns:** `!void`

*Line: 157*

---

### `isFinalized`

Check if a block height is finalized (can never be reverted)

```zig
pub fn isFinalized(self: *const FinalityEngine, block_height: u64) bool {
```

**Parameters:**

- `self`: `*const FinalityEngine`
- `block_height`: `u64`

**Returns:** `bool`

*Line: 205*

---

### `hasSoftFinality`

Check if a block has soft finality (N confirmations, like Bitcoin)

```zig
pub fn hasSoftFinality(_: *const FinalityEngine, block_height: u64, current_height: u64) bool {
```

**Parameters:**

- `_`: `*const FinalityEngine`
- `block_height`: `u64`
- `current_height`: `u64`

**Returns:** `bool`

*Line: 210*

---

### `getLastFinalized`

Get the latest finalized checkpoint

```zig
pub fn getLastFinalized(self: *const FinalityEngine) ?*const Checkpoint {
```

**Parameters:**

- `self`: `*const FinalityEngine`

**Returns:** `?*const Checkpoint`

*Line: 216*

---

