# Module: `shard_coordinator`

> 4-shard routing — assigns addresses to shards, load balancing, cross-shard TX routing.

**Source:** `core/shard_coordinator.zig` | **Lines:** 268 | **Functions:** 8 | **Structs:** 2 | **Tests:** 11

---

## Contents

### Structs
- [`ShardStats`](#shardstats) — Statistici per shard — folosite pentru adaptive sharding
- [`ShardCoordinator`](#shardcoordinator) — ShardCoordinator — rutare adresă→shard + adaptive split/merge

### Constants
- [4 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`getShardForAddress()`](#getshardforaddress) — Rutare adresă → shard_id (EGLD-style: hash primului byte)
La EGLD: ult...
- [`getMyShardId()`](#getmyshardid) — Returnează shard-ul nodului curent (din adresa proprie)
- [`needsSplit()`](#needssplit) — Adaptive sharding: verifică dacă un shard trebuie split
La EGLD: shard...
- [`needsMerge()`](#needsmerge) — Adaptive sharding: verifică dacă două shard-uri trebuie merged
- [`splitShard()`](#splitshard) — Execută split: noul shard primește jumătate din adresele shard-ului or...
- [`mergeShards()`](#mergeshards) — Execută merge: shard_b se dizolvă în shard_a
- [`printStatus()`](#printstatus) — Performs the print status operation on the shard_coordinator module.

---

## Structs

### `ShardStats`

Statistici per shard — folosite pentru adaptive sharding

| Field | Type | Description |
|-------|------|-------------|
| `shard_id` | `u8` | Shard_id |
| `tx_count` | `u64` | Tx_count |
| `capacity_pct` | `u8` | Capacity_pct |
| `node_count` | `u16` | Node_count |
| `active` | `bool` | Active |

*Defined at line 16*

---

### `ShardCoordinator`

ShardCoordinator — rutare adresă→shard + adaptive split/merge

| Field | Type | Description |
|-------|------|-------------|
| `num_shards` | `u8` | Num_shards |
| `allocator` | `std.mem.Allocator` | Allocator |
| `shard_stats` | `[MAX_SHARDS]ShardStats` | Shard_stats |

*Defined at line 25*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `METACHAIN_SHARD` | `u8 = 0xFF` | M e t a c h a i n_ s h a r d |
| `MAX_SHARDS` | `u8 = 32` | M a x_ s h a r d s |
| `SHARD_SPLIT_THRESHOLD` | `u8 = 80` | S h a r d_ s p l i t_ t h r e s h o l d |
| `SHARD_MERGE_THRESHOLD` | `u8 = 20` | S h a r d_ m e r g e_ t h r e s h o l d |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, num_shards: u8) !ShardCoordinator {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `num_shards` | `u8` | Num_shards |

**Returns:** `!ShardCoordinator`

*Defined at line 30*

---

### `getShardForAddress()`

Rutare adresă → shard_id (EGLD-style: hash primului byte)
La EGLD: ultimii biți din adresă encoding-ează shard-ul
La OmniBus: SHA256(address)[0] % num_shards (mai uniform)

```zig
pub fn getShardForAddress(self: *const ShardCoordinator, address: []const u8) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardCoordinator` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `u8`

*Defined at line 51*

---

### `getMyShardId()`

Returnează shard-ul nodului curent (din adresa proprie)

```zig
pub fn getMyShardId(self: *const ShardCoordinator, my_address: []const u8) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardCoordinator` | The instance |
| `my_address` | `[]const u8` | My_address |

**Returns:** `u8`

*Defined at line 73*

---

### `needsSplit()`

Adaptive sharding: verifică dacă un shard trebuie split
La EGLD: shard-ul cu cel mai mare load se împarte în 2

```zig
pub fn needsSplit(self: *const ShardCoordinator) ?u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardCoordinator` | The instance |

**Returns:** `?u8`

*Defined at line 98*

---

### `needsMerge()`

Adaptive sharding: verifică dacă două shard-uri trebuie merged

```zig
pub fn needsMerge(self: *const ShardCoordinator) ?[2]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardCoordinator` | The instance |

**Returns:** `?[2]u8`

*Defined at line 111*

---

### `splitShard()`

Execută split: noul shard primește jumătate din adresele shard-ului original
Returneaza ID-ul noului shard

```zig
pub fn splitShard(self: *ShardCoordinator, shard_id: u8) !u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ShardCoordinator` | The instance |
| `shard_id` | `u8` | Shard_id |

**Returns:** `!u8`

*Defined at line 132*

---

### `mergeShards()`

Execută merge: shard_b se dizolvă în shard_a

```zig
pub fn mergeShards(self: *ShardCoordinator, shard_a: u8, shard_b: u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ShardCoordinator` | The instance |
| `shard_a` | `u8` | Shard_a |
| `shard_b` | `u8` | Shard_b |

**Returns:** `!void`

*Defined at line 149*

---

### `printStatus()`

Performs the print status operation on the shard_coordinator module.

```zig
pub fn printStatus(self: *const ShardCoordinator) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ShardCoordinator` | The instance |

*Defined at line 161*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
