# Module: `kademlia_dht`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `DhtPeer`

DHT Peer entry

*Line: 73*

### `KBucket`

K-Bucket: stores up to K peers at a specific XOR distance range

*Line: 87*

### `DhtRoutingTable`

Kademlia DHT Routing Table

*Line: 164*

## Constants

| Name | Type | Value |
|------|------|-------|
| `NODE_ID_SIZE` | auto | `usize = 20` |
| `K_BUCKET_SIZE` | auto | `usize = 20` |
| `NUM_BUCKETS` | auto | `usize = 160` |
| `ALPHA` | auto | `usize = 3` |
| `MAX_DHT_NODES` | auto | `usize = 256` |
| `BUCKET_REFRESH_INTERVAL` | auto | `u64 = 3600` |
| `NodeId` | auto | `[NODE_ID_SIZE]u8` |

## Functions

### `xorDistance`

Compute XOR distance between two node IDs

```zig
pub fn xorDistance(a: NodeId, b: NodeId) NodeId {
```

**Parameters:**

- `a`: `NodeId`
- `b`: `NodeId`

**Returns:** `NodeId`

*Line: 36*

---

### `bucketIndex`

Find the bucket index for a given distance (leading zero bits count)

```zig
pub fn bucketIndex(distance: NodeId) u8 {
```

**Parameters:**

- `distance`: `NodeId`

**Returns:** `u8`

*Line: 45*

---

### `generateNodeId`

Generate a node ID from a public key or random bytes

```zig
pub fn generateNodeId(seed: []const u8) NodeId {
```

**Parameters:**

- `seed`: `[]const u8`

**Returns:** `NodeId`

*Line: 62*

---

### `isStale`

```zig
pub fn isStale(self: *const DhtPeer, current_time: i64, timeout_sec: i64) bool {
```

**Parameters:**

- `self`: `*const DhtPeer`
- `current_time`: `i64`
- `timeout_sec`: `i64`

**Returns:** `bool`

*Line: 81*

---

### `init`

```zig
pub fn init() KBucket {
```

**Returns:** `KBucket`

*Line: 92*

---

### `addPeer`

Add or update a peer in the bucket

```zig
pub fn addPeer(self: *KBucket, peer: DhtPeer) bool {
```

**Parameters:**

- `self`: `*KBucket`
- `peer`: `DhtPeer`

**Returns:** `bool`

*Line: 101*

---

### `findClosest`

Find closest N peers to target ID in this bucket

```zig
pub fn findClosest(self: *const KBucket, target: NodeId, max_results: usize) [K_BUCKET_SIZE]DhtPeer {
```

**Parameters:**

- `self`: `*const KBucket`
- `target`: `NodeId`
- `max_results`: `usize`

**Returns:** `[K_BUCKET_SIZE]DhtPeer`

*Line: 134*

---

### `init`

```zig
pub fn init(local_id: NodeId) DhtRoutingTable {
```

**Parameters:**

- `local_id`: `NodeId`

**Returns:** `DhtRoutingTable`

*Line: 172*

---

### `addPeer`

Add a peer to the appropriate bucket

```zig
pub fn addPeer(self: *DhtRoutingTable, peer: DhtPeer) bool {
```

**Parameters:**

- `self`: `*DhtRoutingTable`
- `peer`: `DhtPeer`

**Returns:** `bool`

*Line: 183*

---

### `findClosest`

Find the K closest peers to a target ID (across all buckets)

```zig
pub fn findClosest(self: *const DhtRoutingTable, target: NodeId, max_results: usize) [K_BUCKET_SIZE]DhtPeer {
```

**Parameters:**

- `self`: `*const DhtRoutingTable`
- `target`: `NodeId`
- `max_results`: `usize`

**Returns:** `[K_BUCKET_SIZE]DhtPeer`

*Line: 193*

---

### `peerCount`

Get total peer count

```zig
pub fn peerCount(self: *const DhtRoutingTable) usize {
```

**Parameters:**

- `self`: `*const DhtRoutingTable`

**Returns:** `usize`

*Line: 217*

---

### `evictStale`

Remove stale peers

```zig
pub fn evictStale(self: *DhtRoutingTable, current_time: i64, timeout_sec: i64) usize {
```

**Parameters:**

- `self`: `*DhtRoutingTable`
- `current_time`: `i64`
- `timeout_sec`: `i64`

**Returns:** `usize`

*Line: 226*

---

