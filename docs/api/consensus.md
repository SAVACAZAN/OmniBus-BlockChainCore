# Module: `consensus`

> Proof-of-Work consensus engine — SHA256d mining, difficulty validation, block verification, and modular design for future PBFT support.

**Source:** `core/consensus.zig` | **Lines:** 280 | **Functions:** 12 | **Structs:** 4 | **Tests:** 7

---

## Contents

### Structs
- [`ValidatorVote`](#validatorvote) — Starea unui validator in runda curenta
- [`ConsensusConfig`](#consensusconfig) — Configuratia consensului — independenta de blockchain
- [`ConsensusRound`](#consensusround) — Runda de consens pentru un bloc/micro-bloc
- [`ConsensusEngine`](#consensusengine) — Motor de consens simplu — orchestreaza rundele
Modular: poate fi inlocuit cu PBF...

### Constants
- [3 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`byzantineTolerance()`](#byzantinetolerance) — Tolereanta la Byzantine faults (noduri care mint)
- [`print()`](#print) — Performs the print operation on the consensus module.
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`addVote()`](#addvote) — Adauga votul unui validator
Returneaza true daca votul a atins quorum-...
- [`countApproved()`](#countapproved) — Numara voturile de aprobare pentru hash-ul curent
- [`isTimedOut()`](#istimedout) — Verifica daca runda a expirat (timeout)
- [`getResult()`](#getresult) — Returns the current result.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`newRound()`](#newround) — Creeaza o noua runda de consens pentru un bloc
- [`validatePoW()`](#validatepow) — Verifica daca un bloc poate fi acceptat in mod PoW
(compatibil cu codu...
- [`isBlockHashValid()`](#isblockhashvalid) — Quick check: hash-ul unui bloc e valid pentru consensul curent?

---

## Structs

### `ValidatorVote`

Starea unui validator in runda curenta

| Field | Type | Description |
|-------|------|-------------|
| `validator_id` | `u16` | Validator_id |
| `block_hash` | `[32]u8` | Block_hash |
| `approved` | `bool` | Approved |
| `timestamp_ms` | `i64` | Timestamp_ms |

*Defined at line 18*

---

### `ConsensusConfig`

Configuratia consensului — independenta de blockchain

| Field | Type | Description |
|-------|------|-------------|
| `consensus_type` | `ConsensusType` | Consensus_type |
| `total_validators` | `u16` | Total_validators |
| `round_timeout_ms` | `u32` | Round_timeout_ms |
| `min_votes` | `u16` | Min_votes |

*Defined at line 26*

---

### `ConsensusRound`

Runda de consens pentru un bloc/micro-bloc

| Field | Type | Description |
|-------|------|-------------|
| `config` | `ConsensusConfig` | Config |
| `block_hash` | `[32]u8` | Block_hash |
| `votes` | `array_list.Managed(ValidatorVote)` | Votes |
| `started_at` | `i64` | Started_at |
| `finalized` | `bool` | Finalized |
| `allocator` | `std.mem.Allocator` | Allocator |
| `config` | `ConsensusConfig` | Config |
| `block_hash` | `[32]u8` | Block_hash |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 72*

---

### `ConsensusEngine`

Motor de consens simplu — orchestreaza rundele
Modular: poate fi inlocuit cu PBFT complet fara sa schimbe blockchain.zig

| Field | Type | Description |
|-------|------|-------------|
| `config` | `ConsensusConfig` | Config |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 161*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `Block` | `block_mod.Block` | Block |
| `ConsensusType` | `enum {` | Consensus type |
| `Result` | `enum { Approved, Rejected, Timeout, Pending }` | Result |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(ctype: ConsensusType, total_validators: u16) ConsensusConfig {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `ctype` | `ConsensusType` | Ctype |
| `total_validators` | `u16` | Total_validators |

**Returns:** `ConsensusConfig`

*Defined at line 35*

---

### `byzantineTolerance()`

Tolereanta la Byzantine faults (noduri care mint)

```zig
pub fn byzantineTolerance(self: *const ConsensusConfig) u16 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ConsensusConfig` | The instance |

**Returns:** `u16`

*Defined at line 50*

---

### `print()`

Performs the print operation on the consensus module.

```zig
pub fn print(self: *const ConsensusConfig) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ConsensusConfig` | The instance |

*Defined at line 58*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *ConsensusRound) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ConsensusRound` | The instance |

*Defined at line 95*

---

### `addVote()`

Adauga votul unui validator
Returneaza true daca votul a atins quorum-ul si runda e finalizata

```zig
pub fn addVote(self: *ConsensusRound, vote: ValidatorVote) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ConsensusRound` | The instance |
| `vote` | `ValidatorVote` | Vote |

**Returns:** `!bool`

*Defined at line 101*

---

### `countApproved()`

Numara voturile de aprobare pentru hash-ul curent

```zig
pub fn countApproved(self: *const ConsensusRound) u16 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ConsensusRound` | The instance |

**Returns:** `u16`

*Defined at line 124*

---

### `isTimedOut()`

Verifica daca runda a expirat (timeout)

```zig
pub fn isTimedOut(self: *const ConsensusRound) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ConsensusRound` | The instance |

**Returns:** `bool`

*Defined at line 135*

---

### `getResult()`

Returns the current result.

```zig
pub fn getResult(self: *const ConsensusRound) Result {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ConsensusRound` | The instance |

**Returns:** `Result`

*Defined at line 143*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(config: ConsensusConfig, allocator: std.mem.Allocator) ConsensusEngine {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `config` | `ConsensusConfig` | Config |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `ConsensusEngine`

*Defined at line 165*

---

### `newRound()`

Creeaza o noua runda de consens pentru un bloc

```zig
pub fn newRound(self: *const ConsensusEngine, block_hash: [32]u8) ConsensusRound {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ConsensusEngine` | The instance |
| `block_hash` | `[32]u8` | Block_hash |

**Returns:** `ConsensusRound`

*Defined at line 170*

---

### `validatePoW()`

Verifica daca un bloc poate fi acceptat in mod PoW
(compatibil cu codul existent din blockchain.zig)

```zig
pub fn validatePoW(self: *const ConsensusEngine, hash: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ConsensusEngine` | The instance |
| `hash` | `[]const u8` | Hash |

**Returns:** `bool`

*Defined at line 176*

---

### `isBlockHashValid()`

Quick check: hash-ul unui bloc e valid pentru consensul curent?

```zig
pub fn isBlockHashValid(self: *const ConsensusEngine, hash: []const u8, difficulty: u32) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ConsensusEngine` | The instance |
| `hash` | `[]const u8` | Hash |
| `difficulty` | `u32` | Difficulty |

**Returns:** `bool`

*Defined at line 187*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
