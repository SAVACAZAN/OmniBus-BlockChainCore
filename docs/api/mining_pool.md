# Module: `mining_pool`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `MiningPool`

Mining Pool - Coordinates multiple miners

*Line: 5*

### `Miner`

*Line: 13*

### `PoolStats`

*Line: 149*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MinerStatus` | auto | `enum {` |

## Functions

### `init`

```zig
pub fn init(pool_id: []const u8, reward_address: []const u8, allocator: std.mem.Allocator) MiningPool {
```

**Parameters:**

- `pool_id`: `[]const u8`
- `reward_address`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `MiningPool`

*Line: 29*

---

### `deinit`

```zig
pub fn deinit(self: *MiningPool) void {
```

**Parameters:**

- `self`: `*MiningPool`

*Line: 40*

---

### `addMiner`

Add miner to pool

```zig
pub fn addMiner(self: *MiningPool, miner_id: []const u8, address: []const u8, hashrate: u64) !void {
```

**Parameters:**

- `self`: `*MiningPool`
- `miner_id`: `[]const u8`
- `address`: `[]const u8`
- `hashrate`: `u64`

**Returns:** `!void`

*Line: 45*

---

### `updateMinerStatus`

Update miner status

```zig
pub fn updateMinerStatus(self: *MiningPool, miner_id: []const u8, status: MinerStatus) !void {
```

**Parameters:**

- `self`: `*MiningPool`
- `miner_id`: `[]const u8`
- `status`: `MinerStatus`

**Returns:** `!void`

*Line: 62*

---

### `recordShare`

Record share from miner

```zig
pub fn recordShare(self: *MiningPool, miner_id: []const u8) !void {
```

**Parameters:**

- `self`: `*MiningPool`
- `miner_id`: `[]const u8`

**Returns:** `!void`

*Line: 74*

---

### `recordBlockFound`

Record block found

```zig
pub fn recordBlockFound(self: *MiningPool) void {
```

**Parameters:**

- `self`: `*MiningPool`

*Line: 87*

---

### `getMinerCount`

Get miner count

```zig
pub fn getMinerCount(self: *const MiningPool) usize {
```

**Parameters:**

- `self`: `*const MiningPool`

**Returns:** `usize`

*Line: 93*

---

### `getTotalHashrate`

Get total hashrate

```zig
pub fn getTotalHashrate(self: *const MiningPool) u64 {
```

**Parameters:**

- `self`: `*const MiningPool`

**Returns:** `u64`

*Line: 98*

---

### `getStats`

Get pool statistics

```zig
pub fn getStats(self: *const MiningPool) PoolStats {
```

**Parameters:**

- `self`: `*const MiningPool`

**Returns:** `PoolStats`

*Line: 103*

---

### `removeInactiveMiners`

Remove inactive miners (no share for 300s)

```zig
pub fn removeInactiveMiners(self: *MiningPool) void {
```

**Parameters:**

- `self`: `*MiningPool`

*Line: 121*

---

### `getMinerRewardShare`

Get miner reward share (proportional to hashrate)

```zig
pub fn getMinerRewardShare(self: *const MiningPool, miner_id: []const u8, block_reward: u64) !u64 {
```

**Parameters:**

- `self`: `*const MiningPool`
- `miner_id`: `[]const u8`
- `block_reward`: `u64`

**Returns:** `!u64`

*Line: 138*

---

