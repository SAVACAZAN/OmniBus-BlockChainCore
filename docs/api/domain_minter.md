# Module: `domain_minter`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Domain`

Un domeniu mintat pe chain

*Line: 71*

### `DomainRegistry`

*Line: 107*

## Constants

| Name | Type | Value |
|------|------|-------|
| `DomainType` | auto | `enum(u8) {` |
| `MAX_NAME_LEN` | auto | `usize = 32` |
| `MAX_LEVEL` | auto | `u8 = 100` |
| `MAX_DOMAINS` | auto | `usize = 65_536` |

## Functions

### `prefix`

```zig
pub fn prefix(self: DomainType) []const u8 {
```

**Parameters:**

- `self`: `DomainType`

**Returns:** `[]const u8`

*Line: 27*

---

### `algorithm`

```zig
pub fn algorithm(self: DomainType) []const u8 {
```

**Parameters:**

- `self`: `DomainType`

**Returns:** `[]const u8`

*Line: 37*

---

### `isSoulBound`

Domeniile non-transferabile (SoulBound strict)

```zig
pub fn isSoulBound(self: DomainType) bool {
```

**Parameters:**

- `self`: `DomainType`

**Returns:** `bool`

*Line: 48*

---

### `mintCostSat`

Costul de mintare in SAT OMNI

```zig
pub fn mintCostSat(self: DomainType) u64 {
```

**Parameters:**

- `self`: `DomainType`

**Returns:** `u64`

*Line: 56*

---

### `fullName`

```zig
pub fn fullName(self: *const Domain) []const u8 {
```

**Parameters:**

- `self`: `*const Domain`

**Returns:** `[]const u8`

*Line: 94*

---

### `levelUp`

```zig
pub fn levelUp(self: *Domain) void {
```

**Parameters:**

- `self`: `*Domain`

*Line: 98*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) DomainRegistry {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `DomainRegistry`

*Line: 113*

---

### `deinit`

```zig
pub fn deinit(self: *DomainRegistry) void {
```

**Parameters:**

- `self`: `*DomainRegistry`

*Line: 121*

---

### `count`

```zig
pub fn count(self: *const DomainRegistry) usize {
```

**Parameters:**

- `self`: `*const DomainRegistry`

**Returns:** `usize`

*Line: 265*

---

### `printStatus`

```zig
pub fn printStatus(self: *const DomainRegistry) void {
```

**Parameters:**

- `self`: `*const DomainRegistry`

*Line: 273*

---

