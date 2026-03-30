# Module: `ripemd160`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Ripemd160`

*Line: 45*

## Constants

| Name | Type | Value |
|------|------|-------|
| `digest_length` | auto | `20` |

## Functions

### `init`

```zig
pub fn init() Ripemd160 {
```

**Returns:** `Ripemd160`

*Line: 53*

---

### `update`

```zig
pub fn update(self: *Ripemd160, data: []const u8) void {
```

**Parameters:**

- `self`: `*Ripemd160`
- `data`: `[]const u8`

*Line: 62*

---

### `final`

```zig
pub fn final(self: *Ripemd160, out: *[20]u8) void {
```

**Parameters:**

- `self`: `*Ripemd160`
- `out`: `*[20]u8`

*Line: 85*

---

### `hash`

```zig
pub fn hash(data: []const u8, out: *[20]u8) void {
```

**Parameters:**

- `data`: `[]const u8`
- `out`: `*[20]u8`

*Line: 149*

---

