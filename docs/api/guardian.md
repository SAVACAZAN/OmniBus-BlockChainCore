# Module: `guardian`

> Account guardians — social recovery, activation delay (20K blocks), guardian-approved operations for lost keys.

**Source:** `core/guardian.zig` | **Lines:** 249 | **Functions:** 8 | **Structs:** 2 | **Tests:** 7

---

## Contents

### Structs
- [`GuardianRecord`](#guardianrecord) — Guardian record for an account
- [`GuardianEngine`](#guardianengine) — Guardian Engine

### Constants
- [4 constants defined](#constants)

### Functions
- [`isActive()`](#isactive) — Checks whether the active condition is true.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`setGuardian()`](#setguardian) — Set a guardian for an account (starts as pending)
- [`activateGuardian()`](#activateguardian) — Activate a pending guardian (called when activation delay passes)
- [`removeGuardian()`](#removeguardian) — Remove guardian (requires guardian co-signature)
- [`getActiveGuardian()`](#getactiveguardian) — Get active guardian for account (null if none)
- [`requiresGuardian()`](#requiresguardian) — Check if account requires guardian co-signature
- [`guardedCount()`](#guardedcount) — Count guarded accounts

---

## Structs

### `GuardianRecord`

Guardian record for an account

| Field | Type | Description |
|-------|------|-------------|
| `account` | `[32]u8` | Account |
| `guardian_pubkey` | `[33]u8` | Guardian_pubkey |
| `set_block` | `u64` | Set_block |
| `active_block` | `u64` | Active_block |
| `status` | `GuardianStatus` | Status |

*Defined at line 42*

---

### `GuardianEngine`

Guardian Engine

| Field | Type | Description |
|-------|------|-------------|
| `records` | `[MAX_GUARDED_ACCOUNTS]GuardianRecord` | Records |
| `record_count` | `usize` | Record_count |

*Defined at line 60*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `GUARDIAN_ACTIVATION_DELAY` | `u64 = 20_000` | G u a r d i a n_ a c t i v a t i o n_ d e l a y |
| `MAX_GUARDIANS` | `usize = 3` | M a x_ g u a r d i a n s |
| `MAX_GUARDED_ACCOUNTS` | `usize = 4096` | M a x_ g u a r d e d_ a c c o u n t s |
| `GuardianStatus` | `enum(u8) {` | Guardian status |

---

## Functions

### `isActive()`

Checks whether the active condition is true.

```zig
pub fn isActive(self: *const GuardianRecord, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const GuardianRecord` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 54*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() GuardianEngine {
```

**Returns:** `GuardianEngine`

*Defined at line 64*

---

### `setGuardian()`

Set a guardian for an account (starts as pending)

```zig
pub fn setGuardian(self: *GuardianEngine, account: [32]u8, guardian_pubkey: [33]u8, current_block: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*GuardianEngine` | The instance |
| `account` | `[32]u8` | Account |
| `guardian_pubkey` | `[33]u8` | Guardian_pubkey |
| `current_block` | `u64` | Current_block |

**Returns:** `!void`

*Defined at line 72*

---

### `activateGuardian()`

Activate a pending guardian (called when activation delay passes)

```zig
pub fn activateGuardian(self: *GuardianEngine, account: [32]u8, current_block: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*GuardianEngine` | The instance |
| `account` | `[32]u8` | Account |
| `current_block` | `u64` | Current_block |

**Returns:** `!void`

*Defined at line 88*

---

### `removeGuardian()`

Remove guardian (requires guardian co-signature)

```zig
pub fn removeGuardian(self: *GuardianEngine, account: [32]u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*GuardianEngine` | The instance |
| `account` | `[32]u8` | Account |

**Returns:** `!void`

*Defined at line 100*

---

### `getActiveGuardian()`

Get active guardian for account (null if none)

```zig
pub fn getActiveGuardian(self: *const GuardianEngine, account: [32]u8, current_block: u64) ?[33]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const GuardianEngine` | The instance |
| `account` | `[32]u8` | Account |
| `current_block` | `u64` | Current_block |

**Returns:** `?[33]u8`

*Defined at line 113*

---

### `requiresGuardian()`

Check if account requires guardian co-signature

```zig
pub fn requiresGuardian(self: *const GuardianEngine, account: [32]u8, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const GuardianEngine` | The instance |
| `account` | `[32]u8` | Account |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 123*

---

### `guardedCount()`

Count guarded accounts

```zig
pub fn guardedCount(self: *const GuardianEngine, current_block: u64) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const GuardianEngine` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `usize`

*Defined at line 151*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
