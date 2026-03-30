# Module: `finality`

> Casper FFG finality gadget — checkpoint creation, validator attestations, supermajority detection (2/3+1), epoch finalization.

**Source:** `core/finality.zig` | **Lines:** 355 | **Functions:** 7 | **Structs:** 4 | **Tests:** 8

---

## Contents

### Structs
- [`Checkpoint`](#checkpoint) — A checkpoint in the finality chain
- [`Attestation`](#attestation) — Attestation from a validator
- [`SlashingEvidence`](#slashingevidence) — Slashing condition: equivocation (voting for two different blocks at same epoch)
- [`FinalityEngine`](#finalityengine) — Finality Engine

### Constants
- [5 constants defined](#constants)

### Functions
- [`hasSupermajority()`](#hassupermajority) — Check if this checkpoint has supermajority (2/3+)
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`proposeCheckpoint()`](#proposecheckpoint) — Propose a new checkpoint at given block height
- [`attest()`](#attest) — Submit an attestation for a checkpoint
- [`isFinalized()`](#isfinalized) — Check if a block height is finalized (can never be reverted)
- [`hasSoftFinality()`](#hassoftfinality) — Check if a block has soft finality (N confirmations, like Bitcoin)
- [`getLastFinalized()`](#getlastfinalized) — Get the latest finalized checkpoint

---

## Structs

### `Checkpoint`

A checkpoint in the finality chain

| Field | Type | Description |
|-------|------|-------------|
| `epoch` | `u64` | Epoch |
| `block_height` | `u64` | Block_height |
| `block_hash` | `[32]u8` | Block_hash |
| `status` | `CheckpointStatus` | Status |
| `attestation_count` | `u32` | Attestation_count |
| `attested_power` | `u64` | Attested_power |
| `first_attestation_block` | `u64` | First_attestation_block |
| `parent_epoch` | `u64` | Parent_epoch |

*Defined at line 40*

---

### `Attestation`

Attestation from a validator

| Field | Type | Description |
|-------|------|-------------|
| `validator_id` | `u16` | Validator_id |
| `target_epoch` | `u64` | Target_epoch |
| `source_epoch` | `u64` | Source_epoch |
| `voting_power` | `u64` | Voting_power |
| `block_hash` | `[32]u8` | Block_hash |
| `timestamp` | `i64` | Timestamp |

*Defined at line 67*

---

### `SlashingEvidence`

Slashing condition: equivocation (voting for two different blocks at same epoch)

| Field | Type | Description |
|-------|------|-------------|
| `validator_id` | `u16` | Validator_id |
| `epoch` | `u64` | Epoch |
| `hash_a` | `[32]u8` | Hash_a |
| `hash_b` | `[32]u8` | Hash_b |

*Defined at line 82*

---

### `FinalityEngine`

Finality Engine

| Field | Type | Description |
|-------|------|-------------|
| `checkpoints` | `[MAX_CHECKPOINTS]Checkpoint` | Checkpoints |
| `checkpoint_count` | `usize` | Checkpoint_count |
| `last_justified_epoch` | `u64` | Last_justified_epoch |
| `last_finalized_epoch` | `u64` | Last_finalized_epoch |
| `last_finalized_height` | `u64` | Last_finalized_height |
| `total_voting_power` | `u64` | Total_voting_power |
| `validator_votes` | `[MAX_VALIDATORS]u64` | Validator_votes |
| `slash_count` | `u32` | Slash_count |

*Defined at line 92*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `CHECKPOINT_INTERVAL` | `u64 = 64` | C h e c k p o i n t_ i n t e r v a l |
| `SOFT_FINALITY_CONFIRMS` | `u32 = 6` | S o f t_ f i n a l i t y_ c o n f i r m s |
| `MAX_CHECKPOINTS` | `usize = 256` | M a x_ c h e c k p o i n t s |
| `MAX_VALIDATORS` | `usize = 128` | M a x_ v a l i d a t o r s |
| `CheckpointStatus` | `enum(u8) {` | Checkpoint status |

---

## Functions

### `hasSupermajority()`

Check if this checkpoint has supermajority (2/3+)

```zig
pub fn hasSupermajority(self: *const Checkpoint, total_power: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Checkpoint` | The instance |
| `total_power` | `u64` | Total_power |

**Returns:** `bool`

*Defined at line 59*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(total_voting_power: u64) FinalityEngine {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `total_voting_power` | `u64` | Total_voting_power |

**Returns:** `FinalityEngine`

*Defined at line 108*

---

### `proposeCheckpoint()`

Propose a new checkpoint at given block height

```zig
pub fn proposeCheckpoint(self: *FinalityEngine, block_height: u64, block_hash: [32]u8) !u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*FinalityEngine` | The instance |
| `block_height` | `u64` | Block_height |
| `block_hash` | `[32]u8` | Block_hash |

**Returns:** `!u64`

*Defined at line 135*

---

### `attest()`

Submit an attestation for a checkpoint

```zig
pub fn attest(self: *FinalityEngine, attestation: Attestation) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*FinalityEngine` | The instance |
| `attestation` | `Attestation` | Attestation |

**Returns:** `!void`

*Defined at line 157*

---

### `isFinalized()`

Check if a block height is finalized (can never be reverted)

```zig
pub fn isFinalized(self: *const FinalityEngine, block_height: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const FinalityEngine` | The instance |
| `block_height` | `u64` | Block_height |

**Returns:** `bool`

*Defined at line 205*

---

### `hasSoftFinality()`

Check if a block has soft finality (N confirmations, like Bitcoin)

```zig
pub fn hasSoftFinality(_: *const FinalityEngine, block_height: u64, current_height: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `_` | `*const FinalityEngine` | _ |
| `block_height` | `u64` | Block_height |
| `current_height` | `u64` | Current_height |

**Returns:** `bool`

*Defined at line 210*

---

### `getLastFinalized()`

Get the latest finalized checkpoint

```zig
pub fn getLastFinalized(self: *const FinalityEngine) ?*const Checkpoint {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const FinalityEngine` | The instance |

**Returns:** `?*const Checkpoint`

*Defined at line 216*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
