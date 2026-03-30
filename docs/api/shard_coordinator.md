# Module: `shard_coordinator`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `ShardStats`

Statistici per shard — folosite pentru adaptive sharding

*Line: 16*

### `ShardCoordinator`

ShardCoordinator — rutare adresă→shard + adaptive split/merge

*Line: 25*

## Constants

| Name | Type | Value |
|------|------|-------|
| `METACHAIN_SHARD` | auto | `u8 = 0xFF` |
| `MAX_SHARDS` | auto | `u8 = 32` |
| `SHARD_SPLIT_THRESHOLD` | auto | `u8 = 80` |
| `SHARD_MERGE_THRESHOLD` | auto | `u8 = 20` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, num_shards: u8) !ShardCoordinator {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `num_shards`: `u8`

**Returns:** `!ShardCoordinator`

*Line: 30*

---

### `getShardForAddress`

Rutare adresă → shard_id (EGLD-style: hash primului byte)
La EGLD: ultimii biți din adresă encoding-ează shard-ul
La OmniBus: SHA256(address)[0] % num_shards (mai uniform)

```zig
pub fn getShardForAddress(self: *const ShardCoordinator, address: []const u8) u8 {
```

**Parameters:**

- `self`: `*const ShardCoordinator`
- `address`: `[]const u8`

**Returns:** `u8`

*Line: 51*

---

### `getMyShardId`

Returnează shard-ul nodului curent (din adresa proprie)

```zig
pub fn getMyShardId(self: *const ShardCoordinator, my_address: []const u8) u8 {
```

**Parameters:**

- `self`: `*const ShardCoordinator`
- `my_address`: `[]const u8`

**Returns:** `u8`

*Line: 73*

---

### `needsSplit`

Adaptive sharding: verifică dacă un shard trebuie split
La EGLD: shard-ul cu cel mai mare load se împarte în 2

```zig
pub fn needsSplit(self: *const ShardCoordinator) ?u8 {
```

**Parameters:**

- `self`: `*const ShardCoordinator`

**Returns:** `?u8`

*Line: 98*

---

### `needsMerge`

Adaptive sharding: verifică dacă două shard-uri trebuie merged

```zig
pub fn needsMerge(self: *const ShardCoordinator) ?[2]u8 {
```

**Parameters:**

- `self`: `*const ShardCoordinator`

**Returns:** `?[2]u8`

*Line: 111*

---

### `splitShard`

Execută split: noul shard primește jumătate din adresele shard-ului original
Returneaza ID-ul noului shard

```zig
pub fn splitShard(self: *ShardCoordinator, shard_id: u8) !u8 {
```

**Parameters:**

- `self`: `*ShardCoordinator`
- `shard_id`: `u8`

**Returns:** `!u8`

*Line: 132*

---

### `mergeShards`

Execută merge: shard_b se dizolvă în shard_a

```zig
pub fn mergeShards(self: *ShardCoordinator, shard_a: u8, shard_b: u8) !void {
```

**Parameters:**

- `self`: `*ShardCoordinator`
- `shard_a`: `u8`
- `shard_b`: `u8`

**Returns:** `!void`

*Line: 149*

---

### `printStatus`

```zig
pub fn printStatus(self: *const ShardCoordinator) void {
```

**Parameters:**

- `self`: `*const ShardCoordinator`

*Line: 161*

---

