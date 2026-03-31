# Module: `network`

> Network layer — manages peer connections, message routing, broadcast to all peers, connection lifecycle management.

**Source:** `core/network.zig` | **Lines:** 316 | **Functions:** 13 | **Structs:** 4 | **Tests:** 4

---

## Contents

### Structs
- [`NetworkNode`](#networknode) — Network Node - P2P participant
- [`P2PNetwork`](#p2pnetwork) — P2P Network - Manages all connected nodes
- [`NetworkStatus`](#networkstatus) — Data structure for network status. Fields include: total_peers, total_miners, se...
- [`Message`](#message) — P2P Message

### Constants
- [1 constants defined](#constants)

### Functions
- [`getAddress()`](#getaddress) — Get node address string
- [`getEndpoint()`](#getendpoint) — Get node endpoint (host:port)
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`addSeedNode()`](#addseednode) — Add seed node
- [`connectToNode()`](#connecttonode) — Connect to a node
- [`disconnectFromNode()`](#disconnectfromnode) — Disconnect from a node
- [`broadcast()`](#broadcast) — Broadcast message to all peers — delegates to P2PNode.broadcastBlock i...
- [`getPeerCount()`](#getpeercount) — Get connected node count
- [`getMinerCount()`](#getminercount) — Get miner count
- [`isMiner()`](#isminer) — Check if node is miner
- [`getMiners()`](#getminers) — Get all miners
- [`getStatus()`](#getstatus) — Get network status

---

## Structs

### `NetworkNode`

Network Node - P2P participant

| Field | Type | Description |
|-------|------|-------------|
| `node_id` | `[]const u8` | Node_id |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `version` | `[]const u8` | Version |
| `is_miner` | `bool` | Is_miner |
| `allocator` | `std.mem.Allocator` | Allocator |
| `node_id` | `[]const u8` | Node_id |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `version` | `[]const u8` | Version |
| `is_miner` | `bool` | Is_miner |
| `allocator` | `std.mem.Allocator` | Allocator |

*Defined at line 5*

---

### `P2PNetwork`

P2P Network - Manages all connected nodes

| Field | Type | Description |
|-------|------|-------------|
| `local_node` | `NetworkNode` | Local_node |
| `connected_nodes` | `array_list.Managed(NetworkNode)` | Connected_nodes |
| `seed_nodes` | `array_list.Managed(NetworkNode)` | Seed_nodes |
| `allocator` | `std.mem.Allocator` | Allocator |
| `p2p_node_ptr` | `?*anyopaque` | P2p_node_ptr |
| `broadcast_fn` | `?*const fn (node_ptr: *anyopaque` | Broadcast_fn |

*Defined at line 43*

---

### `NetworkStatus`

Data structure for network status. Fields include: total_peers, total_miners, seed_nodes, is_synced.

| Field | Type | Description |
|-------|------|-------------|
| `total_peers` | `usize` | Total_peers |
| `total_miners` | `usize` | Total_miners |
| `seed_nodes` | `usize` | Seed_nodes |
| `is_synced` | `bool` | Is_synced |

*Defined at line 174*

---

### `Message`

P2P Message

| Field | Type | Description |
|-------|------|-------------|
| `message_type` | `MessageType` | Message_type |
| `sender_id` | `[]const u8` | Sender_id |
| `payload` | `[]const u8` | Payload |
| `timestamp` | `i64` | Timestamp |

*Defined at line 209*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MessageType` | `enum {` | Message type |

---

## Functions

### `getAddress()`

Get node address string

```zig
pub fn getAddress(self: *const NetworkNode) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const NetworkNode` | The instance |

**Returns:** `[]const u8`

*Defined at line 32*

---

### `getEndpoint()`

Get node endpoint (host:port)

```zig
pub fn getEndpoint(self: *const NetworkNode, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const NetworkNode` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 37*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(local_node: NetworkNode, allocator: std.mem.Allocator) P2PNetwork {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `local_node` | `NetworkNode` | Local_node |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `P2PNetwork`

*Defined at line 54*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *P2PNetwork) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNetwork` | The instance |

*Defined at line 65*

---

### `addSeedNode()`

Add seed node

```zig
pub fn addSeedNode(self: *P2PNetwork, node: NetworkNode) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNetwork` | The instance |
| `node` | `NetworkNode` | Node |

**Returns:** `!void`

*Defined at line 71*

---

### `connectToNode()`

Connect to a node

```zig
pub fn connectToNode(self: *P2PNetwork, node: NetworkNode) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNetwork` | The instance |
| `node` | `NetworkNode` | Node |

**Returns:** `!void`

*Defined at line 77*

---

### `disconnectFromNode()`

Disconnect from a node

```zig
pub fn disconnectFromNode(self: *P2PNetwork, node_id: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNetwork` | The instance |
| `node_id` | `[]const u8` | Node_id |

**Returns:** `!void`

*Defined at line 90*

---

### `broadcast()`

Broadcast message to all peers — delegates to P2PNode.broadcastBlock if attached

```zig
pub fn broadcast(self: *const P2PNetwork, message: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNetwork` | The instance |
| `message` | `[]const u8` | Message |

**Returns:** `!void`

*Defined at line 113*

---

### `getPeerCount()`

Get connected node count

```zig
pub fn getPeerCount(self: *const P2PNetwork) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNetwork` | The instance |

**Returns:** `usize`

*Defined at line 125*

---

### `getMinerCount()`

Get miner count

```zig
pub fn getMinerCount(self: *const P2PNetwork) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNetwork` | The instance |

**Returns:** `usize`

*Defined at line 130*

---

### `isMiner()`

Check if node is miner

```zig
pub fn isMiner(self: *const P2PNetwork, node_id: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNetwork` | The instance |
| `node_id` | `[]const u8` | Node_id |

**Returns:** `bool`

*Defined at line 141*

---

### `getMiners()`

Get all miners

```zig
pub fn getMiners(self: *const P2PNetwork, allocator: std.mem.Allocator) ![]NetworkNode {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNetwork` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]NetworkNode`

*Defined at line 151*

---

### `getStatus()`

Get network status

```zig
pub fn getStatus(self: *const P2PNetwork) NetworkStatus {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNetwork` | The instance |

**Returns:** `NetworkStatus`

*Defined at line 164*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
