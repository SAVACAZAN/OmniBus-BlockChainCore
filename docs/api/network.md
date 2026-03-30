# Module: `network`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `NetworkNode`

Network Node - P2P participant

*Line: 5*

### `P2PNetwork`

P2P Network - Manages all connected nodes

*Line: 43*

### `NetworkStatus`

*Line: 174*

### `Message`

P2P Message

*Line: 195*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MessageType` | auto | `enum {` |

## Functions

### `getAddress`

Get node address string

```zig
pub fn getAddress(self: *const NetworkNode) []const u8 {
```

**Parameters:**

- `self`: `*const NetworkNode`

**Returns:** `[]const u8`

*Line: 32*

---

### `getEndpoint`

Get node endpoint (host:port)

```zig
pub fn getEndpoint(self: *const NetworkNode, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `*const NetworkNode`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 37*

---

### `init`

```zig
pub fn init(local_node: NetworkNode, allocator: std.mem.Allocator) P2PNetwork {
```

**Parameters:**

- `local_node`: `NetworkNode`
- `allocator`: `std.mem.Allocator`

**Returns:** `P2PNetwork`

*Line: 54*

---

### `deinit`

```zig
pub fn deinit(self: *P2PNetwork) void {
```

**Parameters:**

- `self`: `*P2PNetwork`

*Line: 65*

---

### `addSeedNode`

Add seed node

```zig
pub fn addSeedNode(self: *P2PNetwork, node: NetworkNode) !void {
```

**Parameters:**

- `self`: `*P2PNetwork`
- `node`: `NetworkNode`

**Returns:** `!void`

*Line: 71*

---

### `connectToNode`

Connect to a node

```zig
pub fn connectToNode(self: *P2PNetwork, node: NetworkNode) !void {
```

**Parameters:**

- `self`: `*P2PNetwork`
- `node`: `NetworkNode`

**Returns:** `!void`

*Line: 77*

---

### `disconnectFromNode`

Disconnect from a node

```zig
pub fn disconnectFromNode(self: *P2PNetwork, node_id: []const u8) !void {
```

**Parameters:**

- `self`: `*P2PNetwork`
- `node_id`: `[]const u8`

**Returns:** `!void`

*Line: 90*

---

### `broadcast`

Broadcast message to all peers — delegates to P2PNode.broadcastBlock if attached

```zig
pub fn broadcast(self: *const P2PNetwork, message: []const u8) !void {
```

**Parameters:**

- `self`: `*const P2PNetwork`
- `message`: `[]const u8`

**Returns:** `!void`

*Line: 113*

---

### `getPeerCount`

Get connected node count

```zig
pub fn getPeerCount(self: *const P2PNetwork) usize {
```

**Parameters:**

- `self`: `*const P2PNetwork`

**Returns:** `usize`

*Line: 125*

---

### `getMinerCount`

Get miner count

```zig
pub fn getMinerCount(self: *const P2PNetwork) usize {
```

**Parameters:**

- `self`: `*const P2PNetwork`

**Returns:** `usize`

*Line: 130*

---

### `isMiner`

Check if node is miner

```zig
pub fn isMiner(self: *const P2PNetwork, node_id: []const u8) bool {
```

**Parameters:**

- `self`: `*const P2PNetwork`
- `node_id`: `[]const u8`

**Returns:** `bool`

*Line: 141*

---

### `getMiners`

Get all miners

```zig
pub fn getMiners(self: *const P2PNetwork, allocator: std.mem.Allocator) ![]NetworkNode {
```

**Parameters:**

- `self`: `*const P2PNetwork`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]NetworkNode`

*Line: 151*

---

### `getStatus`

Get network status

```zig
pub fn getStatus(self: *const P2PNetwork) NetworkStatus {
```

**Parameters:**

- `self`: `*const P2PNetwork`

**Returns:** `NetworkStatus`

*Line: 164*

---

