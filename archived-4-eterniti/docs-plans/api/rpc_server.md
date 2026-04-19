# Module: `rpc_server`

> JSON-RPC 2.0 HTTP server on port 8332 — 39 methods including blockchain queries, wallet operations, staking, multisig, payment channels, and mining. Uses ws2_32 on Windows.

**Source:** `core/rpc_server.zig` | **Lines:** 1965 | **Functions:** 8 | **Structs:** 7 | **Tests:** 24

---

## Contents

### Structs
- [`RPCServer`](#rpcserver) — Data structure for r p c server. Fields include: blockchain, wallet, allocator.
- [`RegisteredMiner`](#registeredminer) — Un miner inregistrat in retea (via RPC registerminer)
- [`ServerCtx`](#serverctx) — Context partajat intre thread-uri (blockchain + wallet + module noi)
- [`HTTPConfig`](#httpconfig) — Context extins pentru startHTTP cu module optionale
- [`ConnCtx`](#connctx) — Data structure for conn ctx. Fields include: conn, server_ctx, active_counter.
- [`MinerEntry`](#minerentry) — Data structure representing a miner entry in the rpc_server module.
- [`findOrAdd`](#findoradd) — Data structure representing a find or add in the rpc_server module.

### Constants
- [4 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`getBlockCount()`](#getblockcount) — Returns the current block count.
- [`getBalance()`](#getbalance) — Returns the current balance.
- [`getMempoolSize()`](#getmempoolsize) — Returns the current mempool size.
- [`startHTTP()`](#starthttp) — Porneste serverul HTTP pe portul 8332 (blocking — ruleaza pe thread se...
- [`startHTTPEx()`](#starthttpex) — Versiunea extinsa cu module optionale (mempool, p2p, sync)
- [`main()`](#main) — Performs the main operation on the rpc_server module.

---

## Structs

### `RPCServer`

Data structure for r p c server. Fields include: blockchain, wallet, allocator.

| Field | Type | Description |
|-------|------|-------------|
| `blockchain` | `*Blockchain` | Blockchain |
| `wallet` | `*Wallet` | Wallet |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 30*

---

### `RegisteredMiner`

Un miner inregistrat in retea (via RPC registerminer)

| Field | Type | Description |
|-------|------|-------------|
| `address` | `[64]u8` | Address |
| `address_len` | `u8` | Address_len |
| `node_id` | `[32]u8` | Node_id |
| `node_id_len` | `u8` | Node_id_len |
| `registered_at` | `i64` | Registered_at |

*Defined at line 52*

---

### `ServerCtx`

Context partajat intre thread-uri (blockchain + wallet + module noi)

| Field | Type | Description |
|-------|------|-------------|
| `bc` | `*Blockchain` | Bc |
| `wallet` | `*Wallet` | Wallet |
| `allocator` | `std.mem.Allocator` | Allocator |
| `mempool` | `?*mempool_mod.Mempool` | Mempool |
| `p2p` | `?*p2p_mod.P2PNode` | P2p |
| `sync_mgr` | `?*sync_mod.SyncManager` | Sync_mgr |
| `metrics` | `?*Metrics` | Metrics |
| `staking` | `?*staking_mod.StakingEngine` | Staking |
| `channel_mgr` | `?*payment_mod.ChannelManager` | Channel_mgr |
| `is_idle` | `bool` | Is_idle |
| `registered_miners` | `[MAX_REGISTERED_MINERS]RegisteredMiner` | Registered_miners |
| `registered_miner_count` | `u16` | Registered_miner_count |

*Defined at line 63*

---

### `HTTPConfig`

Context extins pentru startHTTP cu module optionale

| Field | Type | Description |
|-------|------|-------------|
| `mempool` | `?*mempool_mod.Mempool` | Mempool |
| `p2p` | `?*p2p_mod.P2PNode` | P2p |
| `sync_mgr` | `?*sync_mod.SyncManager` | Sync_mgr |
| `metrics` | `?*Metrics` | Metrics |
| `staking` | `?*staking_mod.StakingEngine` | Staking |
| `channel_mgr` | `?*payment_mod.ChannelManager` | Channel_mgr |

*Defined at line 89*

---

### `ConnCtx`

Data structure for conn ctx. Fields include: conn, server_ctx, active_counter.

| Field | Type | Description |
|-------|------|-------------|
| `conn` | `std.net.Server.Connection` | Conn |
| `server_ctx` | `*ServerCtx` | Server_ctx |
| `active_counter` | `*std.atomic.Value(u32)` | Active_counter |

*Defined at line 148*

---

### `MinerEntry`

Data structure representing a miner entry in the rpc_server module.

*Defined at line 1052*

---

### `findOrAdd`

Data structure representing a find or add in the rpc_server module.

*Defined at line 1058*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `Metrics` | `benchmark_mod.Metrics` | Metrics |
| `Blockchain` | `blockchain_mod.Blockchain` | Blockchain |
| `Wallet` | `wallet_mod.Wallet` | Wallet |
| `RPCContext` | `ServerCtx` | R p c context |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, bc: *Blockchain, w: *Wallet) !RPCServer {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `bc` | `*Blockchain` | Bc |
| `w` | `*Wallet` | W |

**Returns:** `!RPCServer`

*Defined at line 35*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(_: *RPCServer) void {}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `_` | `*RPCServer` | _ |

*Defined at line 39*

---

### `getBlockCount()`

Returns the current block count.

```zig
pub fn getBlockCount(self: *RPCServer) u32  { return self.blockchain.getBlockCount(); }
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*RPCServer` | The instance |

**Returns:** `u32`

*Defined at line 41*

---

### `getBalance()`

Returns the current balance.

```zig
pub fn getBalance(self: *RPCServer)    u64  { return self.wallet.getBalance(); }
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*RPCServer` | The instance |

**Returns:** `u64`

*Defined at line 42*

---

### `getMempoolSize()`

Returns the current mempool size.

```zig
pub fn getMempoolSize(self: *RPCServer) u32 { return std.math.cast(u32, self.blockchain.mempool.items.len) orelse std.math.maxInt(u32); }
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*RPCServer` | The instance |

**Returns:** `u32`

*Defined at line 43*

---

### `startHTTP()`

Porneste serverul HTTP pe portul 8332 (blocking — ruleaza pe thread separat)

```zig
pub fn startHTTP(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `bc` | `*Blockchain` | Bc |
| `wallet` | `*Wallet` | Wallet |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!void`

*Defined at line 99*

---

### `startHTTPEx()`

Versiunea extinsa cu module optionale (mempool, p2p, sync)

```zig
pub fn startHTTPEx(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator, cfg: HTTPConfig) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `bc` | `*Blockchain` | Bc |
| `wallet` | `*Wallet` | Wallet |
| `allocator` | `std.mem.Allocator` | Allocator |
| `cfg` | `HTTPConfig` | Cfg |

**Returns:** `!void`

*Defined at line 104*

---

### `main()`

Performs the main operation on the rpc_server module.

```zig
pub fn main() !void {
```

**Returns:** `!void`

*Defined at line 1574*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
