# Module: `bootstrap`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `PeerAddr`

*Line: 5*

### `PeerInfo`

*Line: 106*

### `PeerManager`

*Line: 113*

### `SeedNodeConfig`

Seed Node Configuration

*Line: 208*

### `BootstrapNode`

Bootstrap Node - Entry point for network

*Line: 218*

### `Peer`

*Line: 232*

### `BootstrapStats`

*Line: 330*

### `SeedNodePool`

Multiple Seed Nodes for redundancy

*Line: 338*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MSG_GET_PEERS` | auto | `u8 = 0x10` |
| `MSG_PEER_LIST` | auto | `u8 = 0x11` |
| `SEED_PEERS` | auto | `[_]PeerAddr{` |
| `MIN_DIVERSE_PEERS` | auto | `usize = 4` |
| `MAX_PEERS_PER_SUBNET` | auto | `usize = 2` |
| `NodeStatus` | auto | `enum {` |

## Functions

### `pexRequest`

Trimite MSG_GET_PEERS la un peer conectat

```zig
pub fn pexRequest(conn: *p2p_mod.PeerConnection, allocator: std.mem.Allocator) void {
```

**Parameters:**

- `conn`: `*p2p_mod.PeerConnection`
- `allocator`: `std.mem.Allocator`

*Line: 16*

---

### `isDiversePeer`

Check if peer is from a diverse subnet (anti-eclipse attack protection)

```zig
pub fn isDiversePeer(new_peer: PeerAddr, existing_peers: []const PeerAddr) bool {
```

**Parameters:**

- `new_peer`: `PeerAddr`
- `existing_peers`: `[]const PeerAddr`

**Returns:** `bool`

*Line: 61*

---

### `connectToSeedPeers`

Conecteaza la seed peers hardcodati si salveaza peerii descoperiti in manager.
Best-effort: esecurile de conectare sunt loggate dar ignorate.

```zig
pub fn connectToSeedPeers(manager: *PeerManager, allocator: std.mem.Allocator) void {
```

**Parameters:**

- `manager`: `*PeerManager`
- `allocator`: `std.mem.Allocator`

*Line: 74*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) PeerManager {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `PeerManager`

*Line: 117*

---

### `deinit`

```zig
pub fn deinit(self: *PeerManager) void {
```

**Parameters:**

- `self`: `*PeerManager`

*Line: 124*

---

### `addPeer`

Adauga un peer nou daca nu exista deja (deduplicare dupa IP:port)

```zig
pub fn addPeer(self: *PeerManager, addr: PeerAddr, allocator: std.mem.Allocator) !void {
```

**Parameters:**

- `self`: `*PeerManager`
- `addr`: `PeerAddr`
- `allocator`: `std.mem.Allocator`

**Returns:** `!void`

*Line: 129*

---

### `removePeer`

Elimina un peer dupa IP:port

```zig
pub fn removePeer(self: *PeerManager, addr: PeerAddr) void {
```

**Parameters:**

- `self`: `*PeerManager`
- `addr`: `PeerAddr`

*Line: 150*

---

### `getConnectedCount`

Numarul de peeri conectati

```zig
pub fn getConnectedCount(self: *const PeerManager) usize {
```

**Parameters:**

- `self`: `*const PeerManager`

**Returns:** `usize`

*Line: 163*

---

### `getBestPeer`

Returneaza peer-ul cu cea mai mare inaltime a lantului (best peer)
Returneaza null daca nu exista peeri conectati

```zig
pub fn getBestPeer(self: *const PeerManager) ?PeerInfo {
```

**Parameters:**

- `self`: `*const PeerManager`

**Returns:** `?PeerInfo`

*Line: 173*

---

### `updateHeight`

Actualizeaza inaltimea lantului pentru un peer

```zig
pub fn updateHeight(self: *PeerManager, addr: PeerAddr, height: u64) void {
```

**Parameters:**

- `self`: `*PeerManager`
- `addr`: `PeerAddr`
- `height`: `u64`

*Line: 185*

---

### `setConnected`

Marcheaza peer ca connected/disconnected

```zig
pub fn setConnected(self: *PeerManager, addr: PeerAddr, connected: bool) void {
```

**Parameters:**

- `self`: `*PeerManager`
- `addr`: `PeerAddr`
- `connected`: `bool`

*Line: 196*

---

### `init`

```zig
pub fn init(config: SeedNodeConfig) BootstrapNode {
```

**Parameters:**

- `config`: `SeedNodeConfig`

**Returns:** `BootstrapNode`

*Line: 241*

---

### `deinit`

```zig
pub fn deinit(self: *BootstrapNode) void {
```

**Parameters:**

- `self`: `*BootstrapNode`

*Line: 250*

---

### `registerPeer`

Register new peer node

```zig
pub fn registerPeer(self: *BootstrapNode, peer: Peer) !void {
```

**Parameters:**

- `self`: `*BootstrapNode`
- `peer`: `Peer`

**Returns:** `!void`

*Line: 255*

---

### `getPeerList`

Get list of known peers for new node

```zig
pub fn getPeerList(self: *const BootstrapNode) []const Peer {
```

**Parameters:**

- `self`: `*const BootstrapNode`

**Returns:** `[]const Peer`

*Line: 265*

---

### `updatePeerStatus`

Update peer status (heartbeat)

```zig
pub fn updatePeerStatus(self: *BootstrapNode, node_id: []const u8, latency: u32) !void {
```

**Parameters:**

- `self`: `*BootstrapNode`
- `node_id`: `[]const u8`
- `latency`: `u32`

**Returns:** `!void`

*Line: 270*

---

### `removeStalePeers`

Remove stale peers (no heartbeat for 60s)

```zig
pub fn removeStalePeers(self: *BootstrapNode) void {
```

**Parameters:**

- `self`: `*BootstrapNode`

*Line: 282*

---

### `getStats`

Get node statistics

```zig
pub fn getStats(self: *const BootstrapNode) BootstrapStats {
```

**Parameters:**

- `self`: `*const BootstrapNode`

**Returns:** `BootstrapStats`

*Line: 298*

---

### `setStatus`

Update status

```zig
pub fn setStatus(self: *BootstrapNode, status: NodeStatus) void {
```

**Parameters:**

- `self`: `*BootstrapNode`
- `status`: `NodeStatus`

*Line: 319*

---

### `readyForMining`

Check if ready to start mining

```zig
pub fn readyForMining(self: *const BootstrapNode) bool {
```

**Parameters:**

- `self`: `*const BootstrapNode`

**Returns:** `bool`

*Line: 325*

---

### `init`

```zig
pub fn init(primary_config: SeedNodeConfig, allocator: std.mem.Allocator) SeedNodePool {
```

**Parameters:**

- `primary_config`: `SeedNodeConfig`
- `allocator`: `std.mem.Allocator`

**Returns:** `SeedNodePool`

*Line: 343*

---

### `deinit`

```zig
pub fn deinit(self: *SeedNodePool) void {
```

**Parameters:**

- `self`: `*SeedNodePool`

*Line: 353*

---

### `addSecondaryNode`

Add secondary seed node

```zig
pub fn addSecondaryNode(self: *SeedNodePool, config: SeedNodeConfig) !void {
```

**Parameters:**

- `self`: `*SeedNodePool`
- `config`: `SeedNodeConfig`

**Returns:** `!void`

*Line: 362*

---

### `getAllNodes`

Get all nodes (primary + secondary)

```zig
pub fn getAllNodes(self: *SeedNodePool) usize {
```

**Parameters:**

- `self`: `*SeedNodePool`

**Returns:** `usize`

*Line: 368*

---

### `getTotalPeers`

Get total peer count across all nodes

```zig
pub fn getTotalPeers(self: *const SeedNodePool) usize {
```

**Parameters:**

- `self`: `*const SeedNodePool`

**Returns:** `usize`

*Line: 373*

---

### `isNetworkReady`

Check if network is ready (all nodes synchronized)

```zig
pub fn isNetworkReady(self: *const SeedNodePool) bool {
```

**Parameters:**

- `self`: `*const SeedNodePool`

**Returns:** `bool`

*Line: 384*

---

### `startMining`

Start mining on all nodes

```zig
pub fn startMining(self: *SeedNodePool) void {
```

**Parameters:**

- `self`: `*SeedNodePool`

*Line: 399*

---

