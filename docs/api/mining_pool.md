# Module: `mining_pool`

> Mining pool coordination — dynamic miner registration, fair reward distribution, share submission, pool statistics.

**Source:** `core/mining_pool.zig` | **Lines:** 215 | **Functions:** 11 | **Structs:** 3 | **Tests:** 5

---

## Contents

### Structs
- [`MiningPool`](#miningpool) — Mining Pool - Coordinates multiple miners
- [`Miner`](#miner) — Data structure for miner. Fields include: miner_id, address, hashrate, shares, l...
- [`PoolStats`](#poolstats) — Data structure for pool stats. Fields include: total_miners, active_miners, tota...

### Constants
- [1 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`addMiner()`](#addminer) — Add miner to pool
- [`updateMinerStatus()`](#updateminerstatus) — Update miner status
- [`recordShare()`](#recordshare) — Record share from miner
- [`recordBlockFound()`](#recordblockfound) — Record block found
- [`getMinerCount()`](#getminercount) — Get miner count
- [`getTotalHashrate()`](#gettotalhashrate) — Get total hashrate
- [`getStats()`](#getstats) — Get pool statistics
- [`removeInactiveMiners()`](#removeinactiveminers) — Remove inactive miners (no share for 300s)
- [`getMinerRewardShare()`](#getminerrewardshare) — Get miner reward share (proportional to hashrate)

---

## Structs

### `MiningPool`

Mining Pool - Coordinates multiple miners

| Field | Type | Description |
|-------|------|-------------|
| `pool_id` | `[]const u8` | Pool_id |
| `miners` | `array_list.Managed(Miner)` | Miners |
| `total_hashrate` | `u64` | Total_hashrate |
| `blocks_found` | `u64` | Blocks_found |
| `pool_reward_address` | `[]const u8` | Pool_reward_address |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 5*

---

### `Miner`

Data structure for miner. Fields include: miner_id, address, hashrate, shares, last_share_time.

| Field | Type | Description |
|-------|------|-------------|
| `miner_id` | `[]const u8` | Miner_id |
| `address` | `[]const u8` | Address |
| `hashrate` | `u64` | Hashrate |
| `shares` | `u64` | Shares |
| `last_share_time` | `i64` | Last_share_time |
| `status` | `MinerStatus` | Status |

*Defined at line 13*

---

### `PoolStats`

Data structure for pool stats. Fields include: total_miners, active_miners, total_hashrate, blocks_found.

| Field | Type | Description |
|-------|------|-------------|
| `total_miners` | `usize` | Total_miners |
| `active_miners` | `u32` | Active_miners |
| `total_hashrate` | `u64` | Total_hashrate |
| `blocks_found` | `u64` | Blocks_found |

*Defined at line 149*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MinerStatus` | `enum {` | Miner status |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(pool_id: []const u8, reward_address: []const u8, allocator: std.mem.Allocator) MiningPool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `pool_id` | `[]const u8` | Pool_id |
| `reward_address` | `[]const u8` | Reward_address |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `MiningPool`

*Defined at line 29*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *MiningPool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MiningPool` | The instance |

*Defined at line 40*

---

### `addMiner()`

Add miner to pool

```zig
pub fn addMiner(self: *MiningPool, miner_id: []const u8, address: []const u8, hashrate: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MiningPool` | The instance |
| `miner_id` | `[]const u8` | Miner_id |
| `address` | `[]const u8` | Address |
| `hashrate` | `u64` | Hashrate |

**Returns:** `!void`

*Defined at line 45*

---

### `updateMinerStatus()`

Update miner status

```zig
pub fn updateMinerStatus(self: *MiningPool, miner_id: []const u8, status: MinerStatus) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MiningPool` | The instance |
| `miner_id` | `[]const u8` | Miner_id |
| `status` | `MinerStatus` | Status |

**Returns:** `!void`

*Defined at line 62*

---

### `recordShare()`

Record share from miner

```zig
pub fn recordShare(self: *MiningPool, miner_id: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MiningPool` | The instance |
| `miner_id` | `[]const u8` | Miner_id |

**Returns:** `!void`

*Defined at line 74*

---

### `recordBlockFound()`

Record block found

```zig
pub fn recordBlockFound(self: *MiningPool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MiningPool` | The instance |

*Defined at line 87*

---

### `getMinerCount()`

Get miner count

```zig
pub fn getMinerCount(self: *const MiningPool) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MiningPool` | The instance |

**Returns:** `usize`

*Defined at line 93*

---

### `getTotalHashrate()`

Get total hashrate

```zig
pub fn getTotalHashrate(self: *const MiningPool) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MiningPool` | The instance |

**Returns:** `u64`

*Defined at line 98*

---

### `getStats()`

Get pool statistics

```zig
pub fn getStats(self: *const MiningPool) PoolStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MiningPool` | The instance |

**Returns:** `PoolStats`

*Defined at line 103*

---

### `removeInactiveMiners()`

Remove inactive miners (no share for 300s)

```zig
pub fn removeInactiveMiners(self: *MiningPool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MiningPool` | The instance |

*Defined at line 121*

---

### `getMinerRewardShare()`

Get miner reward share (proportional to hashrate)

```zig
pub fn getMinerRewardShare(self: *const MiningPool, miner_id: []const u8, block_reward: u64) !u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MiningPool` | The instance |
| `miner_id` | `[]const u8` | Miner_id |
| `block_reward` | `u64` | Block_reward |

**Returns:** `!u64`

*Defined at line 138*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
