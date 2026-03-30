# Module: `os_mode`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `OsModeState`

Starea unui modul OS

*Line: 60*

### `OsModeManager`

*Line: 74*

## Constants

| Name | Type | Value |
|------|------|-------|
| `OsMode` | auto | `enum(u8) {` |
| `ModeStatus` | auto | `enum(u8) {` |

## Functions

### `name`

```zig
pub fn name(self: OsMode) []const u8 {
```

**Parameters:**

- `self`: `OsMode`

**Returns:** `[]const u8`

*Line: 33*

---

### `priority`

Prioritatea modului (mai mic = mai prioritar)

```zig
pub fn priority(self: OsMode) u8 {
```

**Parameters:**

- `self`: `OsMode`

**Returns:** `u8`

*Line: 46*

---

### `isActive`

```zig
pub fn isActive(self: *const OsModeState) bool {
```

**Parameters:**

- `self`: `*const OsModeState`

**Returns:** `bool`

*Line: 67*

---

### `init`

```zig
pub fn init() OsModeManager {
```

**Returns:** `OsModeManager`

*Line: 79*

---

### `activate`

Activeaza un modul OS

```zig
pub fn activate(self: *OsModeManager, mode: OsMode) !void {
```

**Parameters:**

- `self`: `*OsModeManager`
- `mode`: `OsMode`

**Returns:** `!void`

*Line: 100*

---

### `pauseMode`

Suspenda un modul OS

```zig
pub fn pauseMode(self: *OsModeManager, mode: OsMode) !void {
```

**Parameters:**

- `self`: `*OsModeManager`
- `mode`: `OsMode`

**Returns:** `!void`

*Line: 111*

---

### `runCycle`

Ruleaza un ciclu pentru toate modurile active (in ordine de prioritate)

```zig
pub fn runCycle(self: *OsModeManager) void {
```

**Parameters:**

- `self`: `*OsModeManager`

*Line: 120*

---

### `isActive`

```zig
pub fn isActive(self: *const OsModeManager, mode: OsMode) bool {
```

**Parameters:**

- `self`: `*const OsModeManager`
- `mode`: `OsMode`

**Returns:** `bool`

*Line: 130*

---

### `activeCount`

```zig
pub fn activeCount(self: *const OsModeManager) u8 {
```

**Parameters:**

- `self`: `*const OsModeManager`

**Returns:** `u8`

*Line: 134*

---

### `printStatus`

```zig
pub fn printStatus(self: *const OsModeManager) void {
```

**Parameters:**

- `self`: `*const OsModeManager`

*Line: 138*

---

