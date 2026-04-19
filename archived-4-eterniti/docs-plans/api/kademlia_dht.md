# Module: `kademlia_dht`

> Kademlia distributed hash table — XOR-based distance metric, k-bucket routing, iterative node lookup, peer discovery without central servers.

**Source:** `core/kademlia_dht.zig` | **Lines:** 352 | **Functions:** 12 | **Structs:** 3 | **Tests:** 13

---

## Contents

### Structs
- [`DhtPeer`](#dhtpeer) — DHT Peer entry
- [`KBucket`](#kbucket) — K-Bucket: stores up to K peers at a specific XOR distance range
- [`DhtRoutingTable`](#dhtroutingtable) — Kademlia DHT Routing Table

### Constants
- [7 constants defined](#constants)

### Functions
- [`xorDistance()`](#xordistance) — Compute XOR distance between two node IDs
- [`bucketIndex()`](#bucketindex) — Find the bucket index for a given distance (leading zero bits count)
- [`generateNodeId()`](#generatenodeid) — Generate a node ID from a public key or random bytes
- [`isStale()`](#isstale) — Checks whether the stale condition is true.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addPeer()`](#addpeer) — Add or update a peer in the bucket
- [`findClosest()`](#findclosest) — Find closest N peers to target ID in this bucket
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addPeer()`](#addpeer) — Add a peer to the appropriate bucket
- [`findClosest()`](#findclosest) — Find the K closest peers to a target ID (across all buckets)
- [`peerCount()`](#peercount) — Get total peer count
- [`evictStale()`](#evictstale) — Remove stale peers

---

## Structs

### `DhtPeer`

DHT Peer entry

| Field | Type | Description |
|-------|------|-------------|
| `id` | `NodeId` | Id |
| `ip` | `[4]u8` | Ip |
| `port` | `u16` | Port |
| `last_seen` | `i64` | Last_seen |
| `rtt_ms` | `u16` | Rtt_ms |

*Defined at line 73*

---

### `KBucket`

K-Bucket: stores up to K peers at a specific XOR distance range

| Field | Type | Description |
|-------|------|-------------|
| `peers` | `[K_BUCKET_SIZE]DhtPeer` | Peers |
| `count` | `u8` | Count |
| `last_refresh` | `i64` | Last_refresh |

*Defined at line 87*

---

### `DhtRoutingTable`

Kademlia DHT Routing Table

| Field | Type | Description |
|-------|------|-------------|
| `local_id` | `NodeId` | Local_id |
| `buckets` | `[NUM_BUCKETS]KBucket` | Buckets |
| `total_peers` | `usize` | Total_peers |

*Defined at line 164*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `NODE_ID_SIZE` | `usize = 20` | N o d e_ i d_ s i z e |
| `K_BUCKET_SIZE` | `usize = 20` | K_ b u c k e t_ s i z e |
| `NUM_BUCKETS` | `usize = 160` | N u m_ b u c k e t s |
| `ALPHA` | `usize = 3` | A l p h a |
| `MAX_DHT_NODES` | `usize = 256` | M a x_ d h t_ n o d e s |
| `BUCKET_REFRESH_INTERVAL` | `u64 = 3600` | B u c k e t_ r e f r e s h_ i n t e r v a l |
| `NodeId` | `[NODE_ID_SIZE]u8` | Node id |

---

## Functions

### `xorDistance()`

Compute XOR distance between two node IDs

```zig
pub fn xorDistance(a: NodeId, b: NodeId) NodeId {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `a` | `NodeId` | A |
| `b` | `NodeId` | B |

**Returns:** `NodeId`

*Defined at line 36*

---

### `bucketIndex()`

Find the bucket index for a given distance (leading zero bits count)

```zig
pub fn bucketIndex(distance: NodeId) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `distance` | `NodeId` | Distance |

**Returns:** `u8`

*Defined at line 45*

---

### `generateNodeId()`

Generate a node ID from a public key or random bytes

```zig
pub fn generateNodeId(seed: []const u8) NodeId {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `seed` | `[]const u8` | Seed |

**Returns:** `NodeId`

*Defined at line 62*

---

### `isStale()`

Checks whether the stale condition is true.

```zig
pub fn isStale(self: *const DhtPeer, current_time: i64, timeout_sec: i64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DhtPeer` | The instance |
| `current_time` | `i64` | Current_time |
| `timeout_sec` | `i64` | Timeout_sec |

**Returns:** `bool`

*Defined at line 81*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() KBucket {
```

**Returns:** `KBucket`

*Defined at line 92*

---

### `addPeer()`

Add or update a peer in the bucket

```zig
pub fn addPeer(self: *KBucket, peer: DhtPeer) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*KBucket` | The instance |
| `peer` | `DhtPeer` | Peer |

**Returns:** `bool`

*Defined at line 101*

---

### `findClosest()`

Find closest N peers to target ID in this bucket

```zig
pub fn findClosest(self: *const KBucket, target: NodeId, max_results: usize) [K_BUCKET_SIZE]DhtPeer {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const KBucket` | The instance |
| `target` | `NodeId` | Target |
| `max_results` | `usize` | Max_results |

**Returns:** `[K_BUCKET_SIZE]DhtPeer`

*Defined at line 134*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(local_id: NodeId) DhtRoutingTable {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `local_id` | `NodeId` | Local_id |

**Returns:** `DhtRoutingTable`

*Defined at line 172*

---

### `addPeer()`

Add a peer to the appropriate bucket

```zig
pub fn addPeer(self: *DhtRoutingTable, peer: DhtPeer) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*DhtRoutingTable` | The instance |
| `peer` | `DhtPeer` | Peer |

**Returns:** `bool`

*Defined at line 183*

---

### `findClosest()`

Find the K closest peers to a target ID (across all buckets)

```zig
pub fn findClosest(self: *const DhtRoutingTable, target: NodeId, max_results: usize) [K_BUCKET_SIZE]DhtPeer {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DhtRoutingTable` | The instance |
| `target` | `NodeId` | Target |
| `max_results` | `usize` | Max_results |

**Returns:** `[K_BUCKET_SIZE]DhtPeer`

*Defined at line 193*

---

### `peerCount()`

Get total peer count

```zig
pub fn peerCount(self: *const DhtRoutingTable) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const DhtRoutingTable` | The instance |

**Returns:** `usize`

*Defined at line 217*

---

### `evictStale()`

Remove stale peers

```zig
pub fn evictStale(self: *DhtRoutingTable, current_time: i64, timeout_sec: i64) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*DhtRoutingTable` | The instance |
| `current_time` | `i64` | Current_time |
| `timeout_sec` | `i64` | Timeout_sec |

**Returns:** `usize`

*Defined at line 226*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
