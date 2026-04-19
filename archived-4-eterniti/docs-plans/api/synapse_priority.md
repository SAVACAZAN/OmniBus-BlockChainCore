# Module: `synapse_priority`

> Synapse scheduler — priority queue for internal node operations, ensures critical tasks execute first.

**Source:** `core/synapse_priority.zig` | **Lines:** 241 | **Functions:** 8 | **Structs:** 2 | **Tests:** 8

---

## Contents

### Structs
- [`SynapseTask`](#synapsetask) — O sarcina (task) in coada de prioritati
- [`SynapseScheduler`](#synapsescheduler) — Data structure for synapse scheduler. Fields include: tasks, task_count, next_ta...

### Constants
- [3 constants defined](#constants)

### Functions
- [`canPreempt()`](#canpreempt) — Performs the can preempt operation on the synapse_priority module.
- [`modePriority()`](#modepriority) — Mapare OsMode → Priority
- [`isOverdue()`](#isoverdue) — Checks whether the overdue condition is true.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`dequeue()`](#dequeue) — Returneaza urmatoarea sarcina de executat (cea cu prioritatea cea mai ...
- [`overdueCount()`](#overduecount) — Verifica daca exista sarcini cu deadline depasit
- [`isEmpty()`](#isempty) — Checks whether the empty condition is true.
- [`printStatus()`](#printstatus) — Performs the print status operation on the synapse_priority module.

---

## Structs

### `SynapseTask`

O sarcina (task) in coada de prioritati

| Field | Type | Description |
|-------|------|-------------|
| `task_id` | `u64` | Task_id |
| `mode` | `OsMode` | Mode |
| `priority` | `Priority` | Priority |
| `queued_at` | `u64` | Queued_at |
| `deadline` | `u64` | Deadline |
| `label` | `[32]u8` | Label |
| `label_len` | `u8` | Label_len |

*Defined at line 48*

---

### `SynapseScheduler`

Data structure for synapse scheduler. Fields include: tasks, task_count, next_task_id, executed_count, preemptions.

| Field | Type | Description |
|-------|------|-------------|
| `tasks` | `[MAX_TASKS]SynapseTask` | Tasks |
| `task_count` | `usize` | Task_count |
| `next_task_id` | `u64` | Next_task_id |
| `executed_count` | `u64` | Executed_count |
| `preemptions` | `u64` | Preemptions |
| `mode` | `OsMode` | Mode |
| `label` | `[]const u8` | Label |
| `queued_at` | `u64` | Queued_at |

*Defined at line 70*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `OsMode` | `os_mode.OsMode` | Os mode |
| `Priority` | `enum(u8) {` | Priority |
| `MAX_TASKS` | `usize = 256` | M a x_ t a s k s |

---

## Functions

### `canPreempt()`

Performs the can preempt operation on the synapse_priority module.

```zig
pub fn canPreempt(self: Priority, other: Priority) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `Priority` | The instance |
| `other` | `Priority` | Other |

**Returns:** `bool`

*Defined at line 29*

---

### `modePriority()`

Mapare OsMode → Priority

```zig
pub fn modePriority(mode: OsMode) Priority {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `mode` | `OsMode` | Mode |

**Returns:** `Priority`

*Defined at line 35*

---

### `isOverdue()`

Checks whether the overdue condition is true.

```zig
pub fn isOverdue(self: *const SynapseTask, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SynapseTask` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 60*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() SynapseScheduler {
```

**Returns:** `SynapseScheduler`

*Defined at line 77*

---

### `dequeue()`

Returneaza urmatoarea sarcina de executat (cea cu prioritatea cea mai mare)
In caz de egalitate: FIFO (task_id mai mic = primul intrat)

```zig
pub fn dequeue(self: *SynapseScheduler) ?SynapseTask {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SynapseScheduler` | The instance |

**Returns:** `?SynapseTask`

*Defined at line 118*

---

### `overdueCount()`

Verifica daca exista sarcini cu deadline depasit

```zig
pub fn overdueCount(self: *const SynapseScheduler, current_block: u64) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SynapseScheduler` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `usize`

*Defined at line 147*

---

### `isEmpty()`

Checks whether the empty condition is true.

```zig
pub fn isEmpty(self: *const SynapseScheduler) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SynapseScheduler` | The instance |

**Returns:** `bool`

*Defined at line 155*

---

### `printStatus()`

Performs the print status operation on the synapse_priority module.

```zig
pub fn printStatus(self: *const SynapseScheduler) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SynapseScheduler` | The instance |

*Defined at line 159*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
