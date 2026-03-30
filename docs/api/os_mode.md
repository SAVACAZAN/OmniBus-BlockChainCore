# Module: `os_mode`

> OS mode detection — detects bare-metal vs hosted mode, adjusts behavior for OmniBus OS integration.

**Source:** `core/os_mode.zig` | **Lines:** 204 | **Functions:** 10 | **Structs:** 2 | **Tests:** 7

---

## Contents

### Structs
- [`OsModeState`](#osmodestate) — Starea unui modul OS
- [`OsModeManager`](#osmodemanager) — Data structure for os mode manager. Fields include: modes, active_mask, current_...

### Constants
- [2 constants defined](#constants)

### Functions
- [`name()`](#name) — Performs the name operation on the os_mode module.
- [`priority()`](#priority) — Prioritatea modului (mai mic = mai prioritar)
- [`isActive()`](#isactive) — Checks whether the active condition is true.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`activate()`](#activate) — Activeaza un modul OS
- [`pauseMode()`](#pausemode) — Suspenda un modul OS
- [`runCycle()`](#runcycle) — Ruleaza un ciclu pentru toate modurile active (in ordine de prioritate...
- [`isActive()`](#isactive) — Checks whether the active condition is true.
- [`activeCount()`](#activecount) — Performs the active count operation on the os_mode module.
- [`printStatus()`](#printstatus) — Performs the print status operation on the os_mode module.

---

## Structs

### `OsModeState`

Starea unui modul OS

| Field | Type | Description |
|-------|------|-------------|
| `mode` | `OsMode` | Mode |
| `status` | `ModeStatus` | Status |
| `activated_block` | `u64` | Activated_block |
| `cycles_run` | `u64` | Cycles_run |
| `last_error` | `?[]const u8` | Last_error |

*Defined at line 60*

---

### `OsModeManager`

Data structure for os mode manager. Fields include: modes, active_mask, current_block.

| Field | Type | Description |
|-------|------|-------------|
| `modes` | `[7]OsModeState` | Modes |
| `active_mask` | `u8` | Active_mask |
| `current_block` | `u64` | Current_block |

*Defined at line 74*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `OsMode` | `enum(u8) {` | Os mode |
| `ModeStatus` | `enum(u8) {` | Mode status |

---

## Functions

### `name()`

Performs the name operation on the os_mode module.

```zig
pub fn name(self: OsMode) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `OsMode` | The instance |

**Returns:** `[]const u8`

*Defined at line 33*

---

### `priority()`

Prioritatea modului (mai mic = mai prioritar)

```zig
pub fn priority(self: OsMode) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `OsMode` | The instance |

**Returns:** `u8`

*Defined at line 46*

---

### `isActive()`

Checks whether the active condition is true.

```zig
pub fn isActive(self: *const OsModeState) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const OsModeState` | The instance |

**Returns:** `bool`

*Defined at line 67*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() OsModeManager {
```

**Returns:** `OsModeManager`

*Defined at line 79*

---

### `activate()`

Activeaza un modul OS

```zig
pub fn activate(self: *OsModeManager, mode: OsMode) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*OsModeManager` | The instance |
| `mode` | `OsMode` | Mode |

**Returns:** `!void`

*Defined at line 100*

---

### `pauseMode()`

Suspenda un modul OS

```zig
pub fn pauseMode(self: *OsModeManager, mode: OsMode) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*OsModeManager` | The instance |
| `mode` | `OsMode` | Mode |

**Returns:** `!void`

*Defined at line 111*

---

### `runCycle()`

Ruleaza un ciclu pentru toate modurile active (in ordine de prioritate)

```zig
pub fn runCycle(self: *OsModeManager) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*OsModeManager` | The instance |

*Defined at line 120*

---

### `isActive()`

Checks whether the active condition is true.

```zig
pub fn isActive(self: *const OsModeManager, mode: OsMode) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const OsModeManager` | The instance |
| `mode` | `OsMode` | Mode |

**Returns:** `bool`

*Defined at line 130*

---

### `activeCount()`

Performs the active count operation on the os_mode module.

```zig
pub fn activeCount(self: *const OsModeManager) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const OsModeManager` | The instance |

**Returns:** `u8`

*Defined at line 134*

---

### `printStatus()`

Performs the print status operation on the os_mode module.

```zig
pub fn printStatus(self: *const OsModeManager) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const OsModeManager` | The instance |

*Defined at line 138*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
