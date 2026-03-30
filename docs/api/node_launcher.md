# Module: `node_launcher`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `NodeConfig`

Node launcher configuration

*Line: 14*

### `NodeLauncher`

Main node launcher

*Line: 29*

## Constants

| Name | Type | Value |
|------|------|-------|
| `NodeMode` | auto | `enum {` |

## Functions

### `init`

```zig
pub fn init(config: NodeConfig) NodeLauncher {
```

**Parameters:**

- `config`: `NodeConfig`

**Returns:** `NodeLauncher`

*Line: 37*

---

### `attachP2PNode`

Ataseaza P2PNode real (TCP) — apelat din main.zig dupa init p2p
Permite broadcast() sa trimita mesaje TCP reale in loc de print-only

```zig
pub fn attachP2PNode(self: *NodeLauncher, node: *p2p_mod.P2PNode) void {
```

**Parameters:**

- `self`: `*NodeLauncher`
- `node`: `*p2p_mod.P2PNode`

*Line: 45*

---

### `startSeedNode`

Start seed node

```zig
pub fn startSeedNode(self: *NodeLauncher) !void {
```

**Parameters:**

- `self`: `*NodeLauncher`

**Returns:** `!void`

*Line: 50*

---

### `startMinerNode`

Start miner node

```zig
pub fn startMinerNode(self: *NodeLauncher) !void {
```

**Parameters:**

- `self`: `*NodeLauncher`

**Returns:** `!void`

*Line: 72*

---

### `registerMinerWithPool`

Register miner with pool (for seed node)

```zig
pub fn registerMinerWithPool(self: *NodeLauncher, miner_id: []const u8, address: []const u8, hashrate: u64) !void {
```

**Parameters:**

- `self`: `*NodeLauncher`
- `miner_id`: `[]const u8`
- `address`: `[]const u8`
- `hashrate`: `u64`

**Returns:** `!void`

*Line: 113*

---

### `onPeerConnected`

Update bootstrap node status when peer joins

```zig
pub fn onPeerConnected(self: *NodeLauncher, peer: bootstrap.BootstrapNode.Peer) !void {
```

**Parameters:**

- `self`: `*NodeLauncher`
- `peer`: `bootstrap.BootstrapNode.Peer`

**Returns:** `!void`

*Line: 124*

---

### `readyForMining`

Transition to mining when ready

```zig
pub fn readyForMining(self: *NodeLauncher) bool {
```

**Parameters:**

- `self`: `*NodeLauncher`

**Returns:** `bool`

*Line: 138*

---

### `startMining`

Start mining on this node

```zig
pub fn startMining(self: *NodeLauncher) !void {
```

**Parameters:**

- `self`: `*NodeLauncher`

**Returns:** `!void`

*Line: 151*

---

### `stopMining`

Stop mining

```zig
pub fn stopMining(self: *NodeLauncher) !void {
```

**Parameters:**

- `self`: `*NodeLauncher`

**Returns:** `!void`

*Line: 171*

---

### `getNetworkStatus`

Get network status

```zig
pub fn getNetworkStatus(self: *const NodeLauncher) ?network.NetworkStatus {
```

**Parameters:**

- `self`: `*const NodeLauncher`

**Returns:** `?network.NetworkStatus`

*Line: 188*

---

### `getBootstrapStatus`

Get bootstrap status

```zig
pub fn getBootstrapStatus(self: *const NodeLauncher) ?bootstrap.BootstrapStats {
```

**Parameters:**

- `self`: `*const NodeLauncher`

**Returns:** `?bootstrap.BootstrapStats`

*Line: 196*

---

### `maintenance`

Periodic maintenance (remove stale peers, etc.)

```zig
pub fn maintenance(self: *NodeLauncher) void {
```

**Parameters:**

- `self`: `*NodeLauncher`

*Line: 204*

---

### `deinit`

```zig
pub fn deinit(self: *NodeLauncher) void {
```

**Parameters:**

- `self`: `*NodeLauncher`

*Line: 210*

---

