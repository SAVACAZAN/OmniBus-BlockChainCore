# Module: `node_launcher`

> Node orchestration — starts all subsystems in order, manages seed/miner mode, initiates mining loop.

**Source:** `core/node_launcher.zig` | **Lines:** 395 | **Functions:** 13 | **Structs:** 2 | **Tests:** 10

---

## Contents

### Structs
- [`NodeConfig`](#nodeconfig) — Node launcher configuration
- [`NodeLauncher`](#nodelauncher) — Main node launcher

### Constants
- [2 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`attachP2PNode()`](#attachp2pnode) — Ataseaza P2PNode real (TCP) — apelat din main.zig dupa init p2p
Permit...
- [`startSeedNode()`](#startseednode) — Start seed node
- [`startMinerNode()`](#startminernode) — Start miner node
- [`registerMinerWithPool()`](#registerminerwithpool) — Register miner with pool (for seed node)
- [`onPeerConnected()`](#onpeerconnected) — Update bootstrap node status when peer joins
- [`readyForMining()`](#readyformining) — Transition to mining when ready (requires MIN_PEERS_FOR_MINING connect...
- [`startMining()`](#startmining) — Start mining on this node
- [`stopMining()`](#stopmining) — Stop mining
- [`getNetworkStatus()`](#getnetworkstatus) — Get network status
- [`getBootstrapStatus()`](#getbootstrapstatus) — Get bootstrap status
- [`maintenance()`](#maintenance) — Periodic maintenance (remove stale peers, etc.)
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.

---

## Structs

### `NodeConfig`

Node launcher configuration

| Field | Type | Description |
|-------|------|-------------|
| `mode` | `NodeMode` | Mode |
| `node_id` | `[]const u8` | Node_id |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `is_primary` | `bool` | Is_primary |
| `max_peers` | `u32` | Max_peers |
| `seed_host` | `?[]const u8` | Seed_host |
| `seed_port` | `?u16` | Seed_port |
| `hashrate` | `?u64` | Hashrate |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 15*

---

### `NodeLauncher`

Main node launcher

| Field | Type | Description |
|-------|------|-------------|
| `config` | `NodeConfig` | Config |
| `bootstrap_node` | `?bootstrap.BootstrapNode` | Bootstrap_node |
| `p2p_network` | `?network.P2PNetwork` | P2p_network |
| `mining_pool` | `?mining_pool.MiningPool` | Mining_pool |
| `p2p_node` | `?*p2p_mod.P2PNode` | P2p_node |
| `is_running` | `bool` | Is_running |

*Defined at line 30*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `NodeMode` | `enum {` | Node mode |
| `MIN_PEERS_FOR_MINING` | `usize = 10` | M i n_ p e e r s_ f o r_ m i n i n g |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(config: NodeConfig) NodeLauncher {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `config` | `NodeConfig` | Config |

**Returns:** `NodeLauncher`

*Defined at line 38*

---

### `attachP2PNode()`

Ataseaza P2PNode real (TCP) — apelat din main.zig dupa init p2p
Permite broadcast() sa trimita mesaje TCP reale in loc de print-only

```zig
pub fn attachP2PNode(self: *NodeLauncher, node: *p2p_mod.P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |
| `node` | `*p2p_mod.P2PNode` | Node |

*Defined at line 46*

---

### `startSeedNode()`

Start seed node

```zig
pub fn startSeedNode(self: *NodeLauncher) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |

**Returns:** `!void`

*Defined at line 51*

---

### `startMinerNode()`

Start miner node

```zig
pub fn startMinerNode(self: *NodeLauncher) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |

**Returns:** `!void`

*Defined at line 73*

---

### `registerMinerWithPool()`

Register miner with pool (for seed node)

```zig
pub fn registerMinerWithPool(self: *NodeLauncher, miner_id: []const u8, address: []const u8, hashrate: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |
| `miner_id` | `[]const u8` | Miner_id |
| `address` | `[]const u8` | Address |
| `hashrate` | `u64` | Hashrate |

**Returns:** `!void`

*Defined at line 114*

---

### `onPeerConnected()`

Update bootstrap node status when peer joins

```zig
pub fn onPeerConnected(self: *NodeLauncher, peer: bootstrap.BootstrapNode.Peer) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |
| `peer` | `bootstrap.BootstrapNode.Peer` | Peer |

**Returns:** `!void`

*Defined at line 125*

---

### `readyForMining()`

Transition to mining when ready (requires MIN_PEERS_FOR_MINING connected)

```zig
pub fn readyForMining(self: *NodeLauncher) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |

**Returns:** `bool`

*Defined at line 143*

---

### `startMining()`

Start mining on this node

```zig
pub fn startMining(self: *NodeLauncher) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |

**Returns:** `!void`

*Defined at line 157*

---

### `stopMining()`

Stop mining

```zig
pub fn stopMining(self: *NodeLauncher) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |

**Returns:** `!void`

*Defined at line 177*

---

### `getNetworkStatus()`

Get network status

```zig
pub fn getNetworkStatus(self: *const NodeLauncher) ?network.NetworkStatus {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const NodeLauncher` | The instance |

**Returns:** `?network.NetworkStatus`

*Defined at line 194*

---

### `getBootstrapStatus()`

Get bootstrap status

```zig
pub fn getBootstrapStatus(self: *const NodeLauncher) ?bootstrap.BootstrapStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const NodeLauncher` | The instance |

**Returns:** `?bootstrap.BootstrapStats`

*Defined at line 202*

---

### `maintenance()`

Periodic maintenance (remove stale peers, etc.)

```zig
pub fn maintenance(self: *NodeLauncher) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |

*Defined at line 210*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *NodeLauncher) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*NodeLauncher` | The instance |

*Defined at line 216*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
