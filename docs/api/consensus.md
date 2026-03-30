# Module: `consensus`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `ValidatorVote`

Starea unui validator in runda curenta

*Line: 18*

### `ConsensusConfig`

Configuratia consensului — independenta de blockchain

*Line: 26*

### `ConsensusRound`

Runda de consens pentru un bloc/micro-bloc

*Line: 72*

### `ConsensusEngine`

Motor de consens simplu — orchestreaza rundele
Modular: poate fi inlocuit cu PBFT complet fara sa schimbe blockchain.zig

*Line: 161*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Block` | auto | `block_mod.Block` |
| `ConsensusType` | auto | `enum {` |
| `Result` | auto | `enum { Approved, Rejected, Timeout, Pending }` |

## Functions

### `init`

```zig
pub fn init(ctype: ConsensusType, total_validators: u16) ConsensusConfig {
```

**Parameters:**

- `ctype`: `ConsensusType`
- `total_validators`: `u16`

**Returns:** `ConsensusConfig`

*Line: 35*

---

### `byzantineTolerance`

Tolereanta la Byzantine faults (noduri care mint)

```zig
pub fn byzantineTolerance(self: *const ConsensusConfig) u16 {
```

**Parameters:**

- `self`: `*const ConsensusConfig`

**Returns:** `u16`

*Line: 50*

---

### `print`

```zig
pub fn print(self: *const ConsensusConfig) void {
```

**Parameters:**

- `self`: `*const ConsensusConfig`

*Line: 58*

---

### `deinit`

```zig
pub fn deinit(self: *ConsensusRound) void {
```

**Parameters:**

- `self`: `*ConsensusRound`

*Line: 95*

---

### `addVote`

Adauga votul unui validator
Returneaza true daca votul a atins quorum-ul si runda e finalizata

```zig
pub fn addVote(self: *ConsensusRound, vote: ValidatorVote) !bool {
```

**Parameters:**

- `self`: `*ConsensusRound`
- `vote`: `ValidatorVote`

**Returns:** `!bool`

*Line: 101*

---

### `countApproved`

Numara voturile de aprobare pentru hash-ul curent

```zig
pub fn countApproved(self: *const ConsensusRound) u16 {
```

**Parameters:**

- `self`: `*const ConsensusRound`

**Returns:** `u16`

*Line: 124*

---

### `isTimedOut`

Verifica daca runda a expirat (timeout)

```zig
pub fn isTimedOut(self: *const ConsensusRound) bool {
```

**Parameters:**

- `self`: `*const ConsensusRound`

**Returns:** `bool`

*Line: 135*

---

### `getResult`

```zig
pub fn getResult(self: *const ConsensusRound) Result {
```

**Parameters:**

- `self`: `*const ConsensusRound`

**Returns:** `Result`

*Line: 143*

---

### `init`

```zig
pub fn init(config: ConsensusConfig, allocator: std.mem.Allocator) ConsensusEngine {
```

**Parameters:**

- `config`: `ConsensusConfig`
- `allocator`: `std.mem.Allocator`

**Returns:** `ConsensusEngine`

*Line: 165*

---

### `newRound`

Creeaza o noua runda de consens pentru un bloc

```zig
pub fn newRound(self: *const ConsensusEngine, block_hash: [32]u8) ConsensusRound {
```

**Parameters:**

- `self`: `*const ConsensusEngine`
- `block_hash`: `[32]u8`

**Returns:** `ConsensusRound`

*Line: 170*

---

### `validatePoW`

Verifica daca un bloc poate fi acceptat in mod PoW
(compatibil cu codul existent din blockchain.zig)

```zig
pub fn validatePoW(self: *const ConsensusEngine, hash: []const u8) bool {
```

**Parameters:**

- `self`: `*const ConsensusEngine`
- `hash`: `[]const u8`

**Returns:** `bool`

*Line: 176*

---

### `isBlockHashValid`

Quick check: hash-ul unui bloc e valid pentru consensul curent?

```zig
pub fn isBlockHashValid(self: *const ConsensusEngine, hash: []const u8, difficulty: u32) bool {
```

**Parameters:**

- `self`: `*const ConsensusEngine`
- `hash`: `[]const u8`
- `difficulty`: `u32`

**Returns:** `bool`

*Line: 187*

---

