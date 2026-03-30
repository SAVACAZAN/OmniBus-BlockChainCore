# Module: `synapse_priority`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `SynapseTask`

O sarcina (task) in coada de prioritati

*Line: 48*

### `SynapseScheduler`

*Line: 70*

## Constants

| Name | Type | Value |
|------|------|-------|
| `OsMode` | auto | `os_mode.OsMode` |
| `Priority` | auto | `enum(u8) {` |
| `MAX_TASKS` | auto | `usize = 256` |

## Functions

### `canPreempt`

```zig
pub fn canPreempt(self: Priority, other: Priority) bool {
```

**Parameters:**

- `self`: `Priority`
- `other`: `Priority`

**Returns:** `bool`

*Line: 29*

---

### `modePriority`

Mapare OsMode → Priority

```zig
pub fn modePriority(mode: OsMode) Priority {
```

**Parameters:**

- `mode`: `OsMode`

**Returns:** `Priority`

*Line: 35*

---

### `isOverdue`

```zig
pub fn isOverdue(self: *const SynapseTask, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const SynapseTask`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 60*

---

### `init`

```zig
pub fn init() SynapseScheduler {
```

**Returns:** `SynapseScheduler`

*Line: 77*

---

### `dequeue`

Returneaza urmatoarea sarcina de executat (cea cu prioritatea cea mai mare)
In caz de egalitate: FIFO (task_id mai mic = primul intrat)

```zig
pub fn dequeue(self: *SynapseScheduler) ?SynapseTask {
```

**Parameters:**

- `self`: `*SynapseScheduler`

**Returns:** `?SynapseTask`

*Line: 118*

---

### `overdueCount`

Verifica daca exista sarcini cu deadline depasit

```zig
pub fn overdueCount(self: *const SynapseScheduler, current_block: u64) usize {
```

**Parameters:**

- `self`: `*const SynapseScheduler`
- `current_block`: `u64`

**Returns:** `usize`

*Line: 147*

---

### `isEmpty`

```zig
pub fn isEmpty(self: *const SynapseScheduler) bool {
```

**Parameters:**

- `self`: `*const SynapseScheduler`

**Returns:** `bool`

*Line: 155*

---

### `printStatus`

```zig
pub fn printStatus(self: *const SynapseScheduler) void {
```

**Parameters:**

- `self`: `*const SynapseScheduler`

*Line: 159*

---

