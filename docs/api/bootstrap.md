# Module: `bootstrap`

> Peer discovery and bootstrapping — seed node connections, PEX (Peer Exchange), DNS seed resolution, peer persistence to disk.

**Source:** `core/bootstrap.zig` | **Lines:** 810 | **Functions:** 29 | **Structs:** 8 | **Tests:** 11

---

## Contents

### Structs
- [`PeerAddr`](#peeraddr) — Data structure for peer addr. Fields include: ip, port.
- [`PeerInfo`](#peerinfo) — Data structure for peer info. Fields include: addr, chain_height, connected, las...
- [`PeerManager`](#peermanager) — Data structure for peer manager. Fields include: known, allocator.
- [`SeedNodeConfig`](#seednodeconfig) — Seed Node Configuration
- [`BootstrapNode`](#bootstrapnode) — Bootstrap Node - Entry point for network
- [`Peer`](#peer) — A network peer — stores connection info (host, port), reputation score, and last...
- [`BootstrapStats`](#bootstrapstats) — Data structure for bootstrap stats. Fields include: uptime_seconds, peer_count, ...
- [`SeedNodePool`](#seednodepool) — Multiple Seed Nodes for redundancy

### Constants
- [11 constants defined](#constants)

### Functions
- [`pexRequest()`](#pexrequest) — Trimite MSG_GET_PEERS la un peer conectat
- [`isDiversePeer()`](#isdiversepeer) — Check if peer is from a diverse subnet (anti-eclipse attack protection...
- [`connectToSeedPeers()`](#connecttoseedpeers) — Conecteaza la seed peers hardcodati si salveaza peerii descoperiti in ...
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`addPeer()`](#addpeer) — Adauga un peer nou daca nu exista deja (deduplicare dupa IP:port)
- [`removePeer()`](#removepeer) — Elimina un peer dupa IP:port
- [`getConnectedCount()`](#getconnectedcount) — Numarul de peeri conectati
- [`getBestPeer()`](#getbestpeer) — Returneaza peer-ul cu cea mai mare inaltime a lantului (best peer)
Ret...
- [`updateHeight()`](#updateheight) — Actualizeaza inaltimea lantului pentru un peer
- [`setConnected()`](#setconnected) — Marcheaza peer ca connected/disconnected
- [`savePeersToDisk()`](#savepeerstodisk) — Save known peers to disk as "host:port\n" lines.
Best-effort: errors a...
- [`loadPeersFromDisk()`](#loadpeersfromdisk) — Load peers from disk file. One peer per line "host:port".
Best-effort:...
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`registerPeer()`](#registerpeer) — Register new peer node
- [`getPeerList()`](#getpeerlist) — Get list of known peers for new node
- [`updatePeerStatus()`](#updatepeerstatus) — Update peer status (heartbeat)
- [`removeStalePeers()`](#removestalepeers) — Remove stale peers (no heartbeat for 60s)
- [`getStats()`](#getstats) — Get node statistics
- [`setStatus()`](#setstatus) — Update status
- [`readyForMining()`](#readyformining) — Performs the ready for mining operation on the bootstrap module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`addSecondaryNode()`](#addsecondarynode) — Add secondary seed node
- [`getAllNodes()`](#getallnodes) — Get all nodes (primary + secondary)
- [`getTotalPeers()`](#gettotalpeers) — Get total peer count across all nodes
- [`isNetworkReady()`](#isnetworkready) — Check if network is ready (all nodes synchronized)
- [`startMining()`](#startmining) — Start mining on all nodes

---

## Structs

### `PeerAddr`

Data structure for peer addr. Fields include: ip, port.

| Field | Type | Description |
|-------|------|-------------|
| `ip` | `[4]u8` | Ip |
| `port` | `u16` | Port |

*Defined at line 5*

---

### `PeerInfo`

Data structure for peer info. Fields include: addr, chain_height, connected, last_seen.

| Field | Type | Description |
|-------|------|-------------|
| `addr` | `PeerAddr` | Addr |
| `chain_height` | `u64` | Chain_height |
| `connected` | `bool` | Connected |
| `last_seen` | `i64` | Last_seen |

*Defined at line 106*

---

### `PeerManager`

Data structure for peer manager. Fields include: known, allocator.

| Field | Type | Description |
|-------|------|-------------|
| `known` | `array_list.Managed(PeerInfo)` | Known |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 113*

---

### `SeedNodeConfig`

Seed Node Configuration

| Field | Type | Description |
|-------|------|-------------|
| `node_id` | `[]const u8` | Node_id |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `is_primary` | `bool` | Is_primary |
| `max_peers` | `u32` | Max_peers |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 411*

---

### `BootstrapNode`

Bootstrap Node - Entry point for network

| Field | Type | Description |
|-------|------|-------------|
| `config` | `SeedNodeConfig` | Config |
| `peers` | `array_list.Managed(Peer)` | Peers |
| `status` | `NodeStatus` | Status |
| `created_at` | `i64` | Created_at |

*Defined at line 421*

---

### `Peer`

A network peer — stores connection info (host, port), reputation score, and last seen timestamp.

| Field | Type | Description |
|-------|------|-------------|
| `node_id` | `[]const u8` | Node_id |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `version` | `[]const u8` | Version |
| `last_seen` | `i64` | Last_seen |
| `latency_ms` | `u32` | Latency_ms |

*Defined at line 435*

---

### `BootstrapStats`

Data structure for bootstrap stats. Fields include: uptime_seconds, peer_count, avg_latency_ms, status.

| Field | Type | Description |
|-------|------|-------------|
| `uptime_seconds` | `i64` | Uptime_seconds |
| `peer_count` | `usize` | Peer_count |
| `avg_latency_ms` | `u32` | Avg_latency_ms |
| `status` | `BootstrapNode.NodeStatus` | Status |

*Defined at line 542*

---

### `SeedNodePool`

Multiple Seed Nodes for redundancy

| Field | Type | Description |
|-------|------|-------------|
| `primary` | `BootstrapNode` | Primary |
| `secondary` | `array_list.Managed(BootstrapNode)` | Secondary |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 550*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MSG_GET_PEERS` | `u8 = 0x10` | M s g_ g e t_ p e e r s |
| `MSG_PEER_LIST` | `u8 = 0x11` | M s g_ p e e r_ l i s t |
| `SEED_PEERS` | `[_]PeerAddr{` | S e e d_ p e e r s |
| `MIN_DIVERSE_PEERS` | `usize = 4` | M i n_ d i v e r s e_ p e e r s |
| `MAX_PEERS_PER_SUBNET` | `usize = 2` | M a x_ p e e r s_ p e r_ s u b n e t |
| `PEERS_DAT_PATH` | `"data/peers.dat"` | P e e r s_ d a t_ p a t h |
| `MAX_PEERS` | `usize = 32` | M a x_ p e e r s |
| `DISCOVERY_INTERVAL_S` | `i64 = 300` | D i s c o v e r y_ i n t e r v a l_ s |
| `PEER_TIMEOUT_S` | `i64 = 1800` | P e e r_ t i m e o u t_ s |
| `NodeStatus` | `enum {` | Node status |
| `MIN_MINERS_FOR_MINING` | `usize = 10` | M i n_ m i n e r s_ f o r_ m i n i n g |

---

## Functions

### `pexRequest()`

Trimite MSG_GET_PEERS la un peer conectat

```zig
pub fn pexRequest(conn: *p2p_mod.PeerConnection, allocator: std.mem.Allocator) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `conn` | `*p2p_mod.PeerConnection` | Conn |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 16*

---

### `isDiversePeer()`

Check if peer is from a diverse subnet (anti-eclipse attack protection)

```zig
pub fn isDiversePeer(new_peer: PeerAddr, existing_peers: []const PeerAddr) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `new_peer` | `PeerAddr` | New_peer |
| `existing_peers` | `[]const PeerAddr` | Existing_peers |

**Returns:** `bool`

*Defined at line 61*

---

### `connectToSeedPeers()`

Conecteaza la seed peers hardcodati si salveaza peerii descoperiti in manager.
Best-effort: esecurile de conectare sunt loggate dar ignorate.

```zig
pub fn connectToSeedPeers(manager: *PeerManager, allocator: std.mem.Allocator) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `manager` | `*PeerManager` | Manager |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 74*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) PeerManager {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `PeerManager`

*Defined at line 117*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *PeerManager) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerManager` | The instance |

*Defined at line 124*

---

### `addPeer()`

Adauga un peer nou daca nu exista deja (deduplicare dupa IP:port)

```zig
pub fn addPeer(self: *PeerManager, addr: PeerAddr, allocator: std.mem.Allocator) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerManager` | The instance |
| `addr` | `PeerAddr` | Addr |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!void`

*Defined at line 129*

---

### `removePeer()`

Elimina un peer dupa IP:port

```zig
pub fn removePeer(self: *PeerManager, addr: PeerAddr) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerManager` | The instance |
| `addr` | `PeerAddr` | Addr |

*Defined at line 150*

---

### `getConnectedCount()`

Numarul de peeri conectati

```zig
pub fn getConnectedCount(self: *const PeerManager) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PeerManager` | The instance |

**Returns:** `usize`

*Defined at line 163*

---

### `getBestPeer()`

Returneaza peer-ul cu cea mai mare inaltime a lantului (best peer)
Returneaza null daca nu exista peeri conectati

```zig
pub fn getBestPeer(self: *const PeerManager) ?PeerInfo {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PeerManager` | The instance |

**Returns:** `?PeerInfo`

*Defined at line 173*

---

### `updateHeight()`

Actualizeaza inaltimea lantului pentru un peer

```zig
pub fn updateHeight(self: *PeerManager, addr: PeerAddr, height: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerManager` | The instance |
| `addr` | `PeerAddr` | Addr |
| `height` | `u64` | Height |

*Defined at line 185*

---

### `setConnected()`

Marcheaza peer ca connected/disconnected

```zig
pub fn setConnected(self: *PeerManager, addr: PeerAddr, connected: bool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerManager` | The instance |
| `addr` | `PeerAddr` | Addr |
| `connected` | `bool` | Connected |

*Defined at line 196*

---

### `savePeersToDisk()`

Save known peers to disk as "host:port\n" lines.
Best-effort: errors are logged but not propagated.

```zig
pub fn savePeersToDisk(manager: *const PeerManager, path: []const u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `manager` | `*const PeerManager` | Manager |
| `path` | `[]const u8` | Path |

*Defined at line 223*

---

### `loadPeersFromDisk()`

Load peers from disk file. One peer per line "host:port".
Best-effort: invalid lines are skipped silently.

```zig
pub fn loadPeersFromDisk(manager: *PeerManager, path: []const u8, allocator: std.mem.Allocator) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `manager` | `*PeerManager` | Manager |
| `path` | `[]const u8` | Path |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 246*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(config: SeedNodeConfig) BootstrapNode {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `config` | `SeedNodeConfig` | Config |

**Returns:** `BootstrapNode`

*Defined at line 444*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *BootstrapNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BootstrapNode` | The instance |

*Defined at line 453*

---

### `registerPeer()`

Register new peer node

```zig
pub fn registerPeer(self: *BootstrapNode, peer: Peer) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BootstrapNode` | The instance |
| `peer` | `Peer` | Peer |

**Returns:** `!void`

*Defined at line 458*

---

### `getPeerList()`

Get list of known peers for new node

```zig
pub fn getPeerList(self: *const BootstrapNode) []const Peer {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BootstrapNode` | The instance |

**Returns:** `[]const Peer`

*Defined at line 468*

---

### `updatePeerStatus()`

Update peer status (heartbeat)

```zig
pub fn updatePeerStatus(self: *BootstrapNode, node_id: []const u8, latency: u32) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BootstrapNode` | The instance |
| `node_id` | `[]const u8` | Node_id |
| `latency` | `u32` | Latency |

**Returns:** `!void`

*Defined at line 473*

---

### `removeStalePeers()`

Remove stale peers (no heartbeat for 60s)

```zig
pub fn removeStalePeers(self: *BootstrapNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BootstrapNode` | The instance |

*Defined at line 485*

---

### `getStats()`

Get node statistics

```zig
pub fn getStats(self: *const BootstrapNode) BootstrapStats {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BootstrapNode` | The instance |

**Returns:** `BootstrapStats`

*Defined at line 501*

---

### `setStatus()`

Update status

```zig
pub fn setStatus(self: *BootstrapNode, status: NodeStatus) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BootstrapNode` | The instance |
| `status` | `NodeStatus` | Status |

*Defined at line 522*

---

### `readyForMining()`

Performs the ready for mining operation on the bootstrap module.

```zig
pub fn readyForMining(self: *const BootstrapNode) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BootstrapNode` | The instance |

**Returns:** `bool`

*Defined at line 534*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(primary_config: SeedNodeConfig, allocator: std.mem.Allocator) SeedNodePool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `primary_config` | `SeedNodeConfig` | Primary_config |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `SeedNodePool`

*Defined at line 555*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *SeedNodePool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SeedNodePool` | The instance |

*Defined at line 565*

---

### `addSecondaryNode()`

Add secondary seed node

```zig
pub fn addSecondaryNode(self: *SeedNodePool, config: SeedNodeConfig) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SeedNodePool` | The instance |
| `config` | `SeedNodeConfig` | Config |

**Returns:** `!void`

*Defined at line 574*

---

### `getAllNodes()`

Get all nodes (primary + secondary)

```zig
pub fn getAllNodes(self: *SeedNodePool) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SeedNodePool` | The instance |

**Returns:** `usize`

*Defined at line 580*

---

### `getTotalPeers()`

Get total peer count across all nodes

```zig
pub fn getTotalPeers(self: *const SeedNodePool) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SeedNodePool` | The instance |

**Returns:** `usize`

*Defined at line 585*

---

### `isNetworkReady()`

Check if network is ready (all nodes synchronized)

```zig
pub fn isNetworkReady(self: *const SeedNodePool) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SeedNodePool` | The instance |

**Returns:** `bool`

*Defined at line 596*

---

### `startMining()`

Start mining on all nodes

```zig
pub fn startMining(self: *SeedNodePool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SeedNodePool` | The instance |

*Defined at line 611*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
