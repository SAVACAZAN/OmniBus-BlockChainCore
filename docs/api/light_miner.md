# Module: `light_miner`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `LightMiner`

Lightweight miner instance (can run multiple on one machine)

*Line: 5*

### `MinerPool`

Manager for multiple light miner instances

*Line: 109*

### `MinerPoolStats`

*Line: 265*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MinerStatus` | auto | `enum {` |
| `PoolStatus` | auto | `enum {` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, id: u32, hashrate: u64) !LightMiner {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `id`: `u32`
- `hashrate`: `u64`

**Returns:** `!LightMiner`

*Line: 18*

---

### `deinit`

```zig
pub fn deinit(self: *LightMiner, allocator: std.mem.Allocator) void {
```

**Parameters:**

- `self`: `*LightMiner`
- `allocator`: `std.mem.Allocator`

*Line: 30*

---

### `connect`

```zig
pub fn connect(self: *LightMiner) void {
```

**Parameters:**

- `self`: `*LightMiner`

*Line: 34*

---

### `disconnect`

```zig
pub fn disconnect(self: *LightMiner) void {
```

**Parameters:**

- `self`: `*LightMiner`

*Line: 40*

---

### `submitShare`

```zig
pub fn submitShare(self: *LightMiner, difficulty: u64) void {
```

**Parameters:**

- `self`: `*LightMiner`
- `difficulty`: `u64`

*Line: 45*

---

### `recordBlockMined`

```zig
pub fn recordBlockMined(self: *LightMiner) void {
```

**Parameters:**

- `self`: `*LightMiner`

*Line: 56*

---

### `getUptime`

```zig
pub fn getUptime(self: *const LightMiner) i64 {
```

**Parameters:**

- `self`: `*const LightMiner`

**Returns:** `i64`

*Line: 61*

---

### `getAcceptanceRate`

```zig
pub fn getAcceptanceRate(self: *const LightMiner) f64 {
```

**Parameters:**

- `self`: `*const LightMiner`

**Returns:** `f64`

*Line: 66*

---

### `getEffectiveHashrate`

```zig
pub fn getEffectiveHashrate(self: *const LightMiner) u64 {
```

**Parameters:**

- `self`: `*const LightMiner`

**Returns:** `u64`

*Line: 71*

---

### `print`

```zig
pub fn print(self: *const LightMiner) void {
```

**Parameters:**

- `self`: `*const LightMiner`

*Line: 83*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) MinerPool {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `MinerPool`

*Line: 117*

---

### `addMiner`

Add new miner to pool

```zig
pub fn addMiner(self: *MinerPool, id: u32, hashrate: u64) !void {
```

**Parameters:**

- `self`: `*MinerPool`
- `id`: `u32`
- `hashrate`: `u64`

**Returns:** `!void`

*Line: 125*

---

### `connectMiner`

Connect miner by ID

```zig
pub fn connectMiner(self: *MinerPool, miner_id: u32) bool {
```

**Parameters:**

- `self`: `*MinerPool`
- `miner_id`: `u32`

**Returns:** `bool`

*Line: 137*

---

### `getMiner`

Get miner by ID

```zig
pub fn getMiner(self: *const MinerPool, miner_id: u32) ?*const LightMiner {
```

**Parameters:**

- `self`: `*const MinerPool`
- `miner_id`: `u32`

**Returns:** `?*const LightMiner`

*Line: 148*

---

### `getConnectedCount`

Get connected miners count

```zig
pub fn getConnectedCount(self: *const MinerPool) u32 {
```

**Parameters:**

- `self`: `*const MinerPool`

**Returns:** `u32`

*Line: 158*

---

### `isReadyForGenesis`

Check if ready for genesis

```zig
pub fn isReadyForGenesis(self: *const MinerPool) bool {
```

**Parameters:**

- `self`: `*const MinerPool`

**Returns:** `bool`

*Line: 167*

---

### `startGenesis`

Start genesis mining

```zig
pub fn startGenesis(self: *MinerPool) !void {
```

**Parameters:**

- `self`: `*MinerPool`

**Returns:** `!void`

*Line: 172*

---

### `submitShare`

Submit share from miner

```zig
pub fn submitShare(self: *MinerPool, miner_id: u32, difficulty: u64) bool {
```

**Parameters:**

- `self`: `*MinerPool`
- `miner_id`: `u32`
- `difficulty`: `u64`

**Returns:** `bool`

*Line: 187*

---

### `getStats`

Get pool statistics

```zig
pub fn getStats(self: *const MinerPool) MinerPoolStats {
```

**Parameters:**

- `self`: `*const MinerPool`

**Returns:** `MinerPoolStats`

*Line: 200*

---

### `printStatus`

Print pool status

```zig
pub fn printStatus(self: *const MinerPool) void {
```

**Parameters:**

- `self`: `*const MinerPool`

*Line: 225*

---

### `deinit`

```zig
pub fn deinit(self: *MinerPool) void {
```

**Parameters:**

- `self`: `*MinerPool`

*Line: 249*

---

