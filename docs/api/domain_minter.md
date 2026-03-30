# Module: `domain_minter`

> PQ domain minting — register domains (omnibus.omni, .love, .food, .rent, .vacation), ownership transfer, lookup by name/owner.

**Source:** `core/domain_minter.zig` | **Lines:** 419 | **Functions:** 10 | **Structs:** 2 | **Tests:** 12

---

## Contents

### Structs
- [`Domain`](#domain) — Un domeniu mintat pe chain
- [`DomainRegistry`](#domainregistry) — Data structure for domain registry. Fields include: allocator, domains, collecte...

### Constants
- [4 constants defined](#constants)

### Functions
- [`prefix()`](#prefix) — Performs the prefix operation on the domain_minter module.
- [`algorithm()`](#algorithm) — Performs the algorithm operation on the domain_minter module.
- [`isSoulBound()`](#issoulbound) — Domeniile non-transferabile (SoulBound strict)
- [`mintCostSat()`](#mintcostsat) — Costul de mintare in SAT OMNI
- [`fullName()`](#fullname) — Performs the full name operation on the domain_minter module.
- [`levelUp()`](#levelup) — Performs the level up operation on the domain_minter module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`count()`](#count) — Returns the count of .
- [`printStatus()`](#printstatus) — Performs the print status operation on the domain_minter module.

---

## Structs

### `Domain`

Un domeniu mintat pe chain

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[MAX_NAME_LEN]u8` | Name |
| `name_len` | `u8` | Name_len |
| `domain_type` | `DomainType` | Domain_type |
| `owner` | `[32]u8` | Owner |
| `level` | `u8` | Level |
| `minted_block` | `u64` | Minted_block |
| `active` | `bool` | Active |

*Defined at line 71*

---

### `DomainRegistry`

Data structure for domain registry. Fields include: allocator, domains, collected_sat, domain_type, username.

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `domains` | `std.array_list.Managed(Domain)` | Domains |
| `collected_sat` | `u64` | Collected_sat |
| `domain_type` | `DomainType` | Domain_type |
| `username` | `[]const u8` | Username |
| `owner` | `[32]u8` | Owner |
| `current_block` | `u64` | Current_block |

*Defined at line 107*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `DomainType` | `enum(u8) {` | Domain type |
| `MAX_NAME_LEN` | `usize = 32` | M a x_ n a m e_ l e n |
| `MAX_LEVEL` | `u8 = 100` | M a x_ l e v e l |
| `MAX_DOMAINS` | `usize = 65_536` | M a x_ d o m a i n s |

---

## Functions

### `prefix()`

Performs the prefix operation on the domain_minter module.

```zig
pub fn prefix(self: DomainType) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `DomainType` | The instance |

**Returns:** `[]const u8`

*Defined at line 27*

---

### `algorithm()`

Performs the algorithm operation on the domain_minter module.

```zig
pub fn algorithm(self: DomainType) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `DomainType` | The instance |

**Returns:** `[]const u8`

*Defined at line 37*

---

### `isSoulBound()`

Domeniile non-transferabile (SoulBound strict)

```zig
pub fn isSoulBound(self: DomainType) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `DomainType` | The instance |

**Returns:** `bool`

*Defined at line 48*

---

### `mintCostSat()`

Costul de mintare in SAT OMNI

```zig
pub fn mintCostSat(self: DomainType) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `DomainType` | The instance |

**Returns:** `u64`

*Defined at line 56*

---

### `fullName()`

Performs the full name operation on the domain_minter module.

```zig
pub fn fullName(self: *const Domain) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Domain` | The instance |

**Returns:** `[]const u8`

*Defined at line 94*

---

### `levelUp()`

Performs the level up operation on the domain_minter module.

```zig
pub fn levelUp(self: *Domain) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Domain` | The instance |

*Defined at line 98*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) DomainRegistry {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `DomainRegistry`

*Defined at line 113*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *DomainRegistry) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*DomainRegistry` | The instance |

*Defined at line 121*

---

### `count()`

Returns the count of .

```zig
pub fn count(self: *const DomainRegistry) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DomainRegistry` | The instance |

**Returns:** `usize`

*Defined at line 265*

---

### `printStatus()`

Performs the print status operation on the domain_minter module.

```zig
pub fn printStatus(self: *const DomainRegistry) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DomainRegistry` | The instance |

*Defined at line 273*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
