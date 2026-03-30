# Module: `guardian`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `GuardianRecord`

Guardian record for an account

*Line: 42*

### `GuardianEngine`

Guardian Engine

*Line: 60*

## Constants

| Name | Type | Value |
|------|------|-------|
| `GUARDIAN_ACTIVATION_DELAY` | auto | `u64 = 20_000` |
| `MAX_GUARDIANS` | auto | `usize = 3` |
| `MAX_GUARDED_ACCOUNTS` | auto | `usize = 4096` |
| `GuardianStatus` | auto | `enum(u8) {` |

## Functions

### `isActive`

```zig
pub fn isActive(self: *const GuardianRecord, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const GuardianRecord`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 54*

---

### `init`

```zig
pub fn init() GuardianEngine {
```

**Returns:** `GuardianEngine`

*Line: 64*

---

### `setGuardian`

Set a guardian for an account (starts as pending)

```zig
pub fn setGuardian(self: *GuardianEngine, account: [32]u8, guardian_pubkey: [33]u8, current_block: u64) !void {
```

**Parameters:**

- `self`: `*GuardianEngine`
- `account`: `[32]u8`
- `guardian_pubkey`: `[33]u8`
- `current_block`: `u64`

**Returns:** `!void`

*Line: 72*

---

### `activateGuardian`

Activate a pending guardian (called when activation delay passes)

```zig
pub fn activateGuardian(self: *GuardianEngine, account: [32]u8, current_block: u64) !void {
```

**Parameters:**

- `self`: `*GuardianEngine`
- `account`: `[32]u8`
- `current_block`: `u64`

**Returns:** `!void`

*Line: 88*

---

### `removeGuardian`

Remove guardian (requires guardian co-signature)

```zig
pub fn removeGuardian(self: *GuardianEngine, account: [32]u8) !void {
```

**Parameters:**

- `self`: `*GuardianEngine`
- `account`: `[32]u8`

**Returns:** `!void`

*Line: 100*

---

### `getActiveGuardian`

Get active guardian for account (null if none)

```zig
pub fn getActiveGuardian(self: *const GuardianEngine, account: [32]u8, current_block: u64) ?[33]u8 {
```

**Parameters:**

- `self`: `*const GuardianEngine`
- `account`: `[32]u8`
- `current_block`: `u64`

**Returns:** `?[33]u8`

*Line: 113*

---

### `requiresGuardian`

Check if account requires guardian co-signature

```zig
pub fn requiresGuardian(self: *const GuardianEngine, account: [32]u8, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const GuardianEngine`
- `account`: `[32]u8`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 123*

---

### `guardedCount`

Count guarded accounts

```zig
pub fn guardedCount(self: *const GuardianEngine, current_block: u64) usize {
```

**Parameters:**

- `self`: `*const GuardianEngine`
- `current_block`: `u64`

**Returns:** `usize`

*Line: 151*

---

