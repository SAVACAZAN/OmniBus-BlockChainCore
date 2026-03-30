# Module: `light_miner`

> Lightweight mining client — reduced resource usage, header-only validation, connects to full nodes for block templates.

**Source:** `core/light_miner.zig` | **Lines:** 351 | **Functions:** 21 | **Structs:** 3 | **Tests:** 6

---

## Contents

### Structs
- [`LightMiner`](#lightminer) — Lightweight miner instance (can run multiple on one machine)
- [`MinerPool`](#minerpool) — Manager for multiple light miner instances
- [`MinerPoolStats`](#minerpoolstats) — Data structure for miner pool stats. Fields include: connected_miners, total_min...

### Constants
- [2 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`connect()`](#connect) — Performs the connect operation on the light_miner module.
- [`disconnect()`](#disconnect) — Performs the disconnect operation on the light_miner module.
- [`submitShare()`](#submitshare) — Performs the submit share operation on the light_miner module.
- [`recordBlockMined()`](#recordblockmined) — Executes mining operation — finds valid nonce for the next block.
- [`getUptime()`](#getuptime) — Returns the current uptime.
- [`getAcceptanceRate()`](#getacceptancerate) — Returns the current acceptance rate.
- [`getEffectiveHashrate()`](#geteffectivehashrate) — Returns the current effective hashrate.
- [`print()`](#print) — Performs the print operation on the light_miner module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addMiner()`](#addminer) — Add new miner to pool
- [`connectMiner()`](#connectminer) — Connect miner by ID
- [`getMiner()`](#getminer) — Get miner by ID
- [`getConnectedCount()`](#getconnectedcount) — Get connected miners count
- [`isReadyForGenesis()`](#isreadyforgenesis) — Check if ready for genesis
- [`startGenesis()`](#startgenesis) — Start genesis mining
- [`submitShare()`](#submitshare) — Submit share from miner
- [`getStats()`](#getstats) — Get pool statistics
- [`printStatus()`](#printstatus) — Print pool status
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.

---

## Structs

### `LightMiner`

Lightweight miner instance (can run multiple on one machine)

| Field | Type | Description |
|-------|------|-------------|
| `miner_id` | `u32` | Miner_id |
| `instance_name` | `[]const u8` | Instance_name |
| `hashrate` | `u64` | Hashrate |
| `status` | `MinerStatus` | Status |
| `blocks_mined` | `u32` | Blocks_mined |
| `shares_submitted` | `u32` | Shares_submitted |
| `shares_accepted` | `u32` | Shares_accepted |
| `last_share_time` | `i64` | Last_share_time |
| `total_difficulty` | `u64` | Total_difficulty |
| `connection_time` | `i64` | Connection_time |
| `is_connected` | `bool` | Is_connected |

*Defined at line 5*

---

### `MinerPool`

Manager for multiple light miner instances

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `miners` | `std.array_list.Managed(LightMiner)` | Miners |
| `total_hashrate` | `u64` | Total_hashrate |
| `pool_status` | `PoolStatus` | Pool_status |
| `genesis_started` | `bool` | Genesis_started |
| `min_miners_for_genesis` | `u32` | Min_miners_for_genesis |

*Defined at line 109*

---

### `MinerPoolStats`

Data structure for miner pool stats. Fields include: connected_miners, total_miners, total_hashrate, total_shares, total_accepted.

| Field | Type | Description |
|-------|------|-------------|
| `connected_miners` | `u32` | Connected_miners |
| `total_miners` | `u32` | Total_miners |
| `total_hashrate` | `u64` | Total_hashrate |
| `total_shares` | `u64` | Total_shares |
| `total_accepted` | `u64` | Total_accepted |
| `total_blocks` | `u32` | Total_blocks |
| `status` | `PoolStatus` | Status |
| `genesis_started` | `bool` | Genesis_started |
| `ready_for_genesis` | `bool` | Ready_for_genesis |

*Defined at line 265*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MinerStatus` | `enum {` | Miner status |
| `PoolStatus` | `enum {` | Pool status |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, id: u32, hashrate: u64) !LightMiner {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `id` | `u32` | Id |
| `hashrate` | `u64` | Hashrate |

**Returns:** `!LightMiner`

*Defined at line 18*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *LightMiner, allocator: std.mem.Allocator) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightMiner` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 30*

---

### `connect()`

Performs the connect operation on the light_miner module.

```zig
pub fn connect(self: *LightMiner) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightMiner` | The instance |

*Defined at line 34*

---

### `disconnect()`

Performs the disconnect operation on the light_miner module.

```zig
pub fn disconnect(self: *LightMiner) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightMiner` | The instance |

*Defined at line 40*

---

### `submitShare()`

Performs the submit share operation on the light_miner module.

```zig
pub fn submitShare(self: *LightMiner, difficulty: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightMiner` | The instance |
| `difficulty` | `u64` | Difficulty |

*Defined at line 45*

---

### `recordBlockMined()`

Executes mining operation — finds valid nonce for the next block.

```zig
pub fn recordBlockMined(self: *LightMiner) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightMiner` | The instance |

*Defined at line 56*

---

### `getUptime()`

Returns the current uptime.

```zig
pub fn getUptime(self: *const LightMiner) i64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightMiner` | The instance |

**Returns:** `i64`

*Defined at line 61*

---

### `getAcceptanceRate()`

Returns the current acceptance rate.

```zig
pub fn getAcceptanceRate(self: *const LightMiner) f64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightMiner` | The instance |

**Returns:** `f64`

*Defined at line 66*

---

### `getEffectiveHashrate()`

Returns the current effective hashrate.

```zig
pub fn getEffectiveHashrate(self: *const LightMiner) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightMiner` | The instance |

**Returns:** `u64`

*Defined at line 71*

---

### `print()`

Performs the print operation on the light_miner module.

```zig
pub fn print(self: *const LightMiner) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightMiner` | The instance |

*Defined at line 83*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) MinerPool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `MinerPool`

*Defined at line 117*

---

### `addMiner()`

Add new miner to pool

```zig
pub fn addMiner(self: *MinerPool, id: u32, hashrate: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerPool` | The instance |
| `id` | `u32` | Id |
| `hashrate` | `u64` | Hashrate |

**Returns:** `!void`

*Defined at line 125*

---

### `connectMiner()`

Connect miner by ID

```zig
pub fn connectMiner(self: *MinerPool, miner_id: u32) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerPool` | The instance |
| `miner_id` | `u32` | Miner_id |

**Returns:** `bool`

*Defined at line 137*

---

### `getMiner()`

Get miner by ID

```zig
pub fn getMiner(self: *const MinerPool, miner_id: u32) ?*const LightMiner {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerPool` | The instance |
| `miner_id` | `u32` | Miner_id |

**Returns:** `?*const LightMiner`

*Defined at line 148*

---

### `getConnectedCount()`

Get connected miners count

```zig
pub fn getConnectedCount(self: *const MinerPool) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerPool` | The instance |

**Returns:** `u32`

*Defined at line 158*

---

### `isReadyForGenesis()`

Check if ready for genesis

```zig
pub fn isReadyForGenesis(self: *const MinerPool) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerPool` | The instance |

**Returns:** `bool`

*Defined at line 167*

---

### `startGenesis()`

Start genesis mining

```zig
pub fn startGenesis(self: *MinerPool) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerPool` | The instance |

**Returns:** `!void`

*Defined at line 172*

---

### `submitShare()`

Submit share from miner

```zig
pub fn submitShare(self: *MinerPool, miner_id: u32, difficulty: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerPool` | The instance |
| `miner_id` | `u32` | Miner_id |
| `difficulty` | `u64` | Difficulty |

**Returns:** `bool`

*Defined at line 187*

---

### `getStats()`

Get pool statistics

```zig
pub fn getStats(self: *const MinerPool) MinerPoolStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerPool` | The instance |

**Returns:** `MinerPoolStats`

*Defined at line 200*

---

### `printStatus()`

Print pool status

```zig
pub fn printStatus(self: *const MinerPool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerPool` | The instance |

*Defined at line 225*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *MinerPool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerPool` | The instance |

*Defined at line 249*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
