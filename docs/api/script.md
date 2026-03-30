# Module: `script`

> Transaction scripting engine — Bitcoin-style script opcodes, P2PKH/P2SH script evaluation, programmable spending conditions.

**Source:** `core/script.zig` | **Lines:** 736 | **Functions:** 10 | **Structs:** 1 | **Tests:** 23

---

## Contents

### Structs
- [`ScriptVM`](#scriptvm) — Data structure for script v m. Fields include: stack, stack_sizes, sp.

### Constants
- [3 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`push()`](#push) — Push data onto the stack
- [`pop()`](#pop) — Pop top item from stack, returns a slice into internal buffer
- [`peek()`](#peek) — Peek at top item without removing
- [`execute()`](#execute) — Execute a script (byte array of opcodes + data pushes)
Returns true if...
- [`createP2PKH()`](#createp2pkh) — Create standard P2PKH locking script:
OP_DUP OP_HASH160 <20-byte pubke...
- [`createP2PKHUnlock()`](#createp2pkhunlock) — Create P2PKH unlocking script: <64-byte sig> <33-byte pubkey>
Layout: ...
- [`createP2SH()`](#createp2sh) — Create P2SH locking script: OP_HASH160 <20-byte script_hash> OP_EQUAL
- [`createOpReturn()`](#createopreturn) — Create OP_RETURN data carrier script
- [`validateScripts()`](#validatescripts) — Validate P2PKH: run unlock_script then lock_script on the same VM.
Ret...

---

## Structs

### `ScriptVM`

Data structure for script v m. Fields include: stack, stack_sizes, sp.

| Field | Type | Description |
|-------|------|-------------|
| `stack` | `[256][80]u8` | Stack |
| `stack_sizes` | `[256]u8` | Stack_sizes |
| `sp` | `u8` | Sp |

*Defined at line 54*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `OpCode` | `enum(u8) {` | Op code |
| `ScriptError` | `error{` | Script error |
| `MAX_MULTISIG_SCRIPT_LEN` | `usize = 3 + 20 * 34` | M a x_ m u l t i s i g_ s c r i p t_ l e n |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() ScriptVM {
```

**Returns:** `ScriptVM`

*Defined at line 59*

---

### `push()`

Push data onto the stack

```zig
pub fn push(self: *ScriptVM, data: []const u8) ScriptError!void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ScriptVM` | The instance |
| `data` | `[]const u8` | Data |

**Returns:** `ScriptError!void`

*Defined at line 68*

---

### `pop()`

Pop top item from stack, returns a slice into internal buffer

```zig
pub fn pop(self: *ScriptVM) ScriptError!struct { data: [80]u8, len: u8 } {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ScriptVM` | The instance |

**Returns:** `ScriptError!struct`

*Defined at line 89*

---

### `peek()`

Peek at top item without removing

```zig
pub fn peek(self: *ScriptVM) ScriptError!struct { data: [80]u8, len: u8 } {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ScriptVM` | The instance |

**Returns:** `ScriptError!struct`

*Defined at line 99*

---

### `execute()`

Execute a script (byte array of opcodes + data pushes)
Returns true if script succeeds (stack top is truthy or stack is empty for
vacuously-valid scripts)

```zig
pub fn execute(self: *ScriptVM, script: []const u8, tx_hash: [32]u8, current_height: u64) ScriptError!bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ScriptVM` | The instance |
| `script` | `[]const u8` | Script |
| `tx_hash` | `[32]u8` | Tx_hash |
| `current_height` | `u64` | Current_height |

**Returns:** `ScriptError!bool`

*Defined at line 128*

---

### `createP2PKH()`

Create standard P2PKH locking script:
OP_DUP OP_HASH160 <20-byte pubkey_hash> OP_EQUALVERIFY OP_CHECKSIG

```zig
pub fn createP2PKH(pubkey_hash: [20]u8) [25]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `pubkey_hash` | `[20]u8` | Pubkey_hash |

**Returns:** `[25]u8`

*Defined at line 333*

---

### `createP2PKHUnlock()`

Create P2PKH unlocking script: <64-byte sig> <33-byte pubkey>
Layout: [push 64] [sig...] [push 33] [pubkey...]

```zig
pub fn createP2PKHUnlock(signature: [64]u8, pubkey: [33]u8) [99]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `signature` | `[64]u8` | Signature |
| `pubkey` | `[33]u8` | Pubkey |

**Returns:** `[99]u8`

*Defined at line 346*

---

### `createP2SH()`

Create P2SH locking script: OP_HASH160 <20-byte script_hash> OP_EQUAL

```zig
pub fn createP2SH(script_hash: [20]u8) [23]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `script_hash` | `[20]u8` | Script_hash |

**Returns:** `[23]u8`

*Defined at line 356*

---

### `createOpReturn()`

Create OP_RETURN data carrier script

```zig
pub fn createOpReturn(data: []const u8) ScriptError![82]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `ScriptError![82]u8`

*Defined at line 366*

---

### `validateScripts()`

Validate P2PKH: run unlock_script then lock_script on the same VM.
Returns true if the combined execution leaves a truthy value on stack.

```zig
pub fn validateScripts(unlock: []const u8, lock: []const u8, tx_hash: [32]u8, height: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `unlock` | `[]const u8` | Unlock |
| `lock` | `[]const u8` | Lock |
| `tx_hash` | `[32]u8` | Tx_hash |
| `height` | `u64` | Height |

**Returns:** `bool`

*Defined at line 429*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
